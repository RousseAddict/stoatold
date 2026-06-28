import UIKit
import WebRTC

/// Manages the LiveKit dual-PeerConnection model for voice rooms:
///   • publisherPC  — client creates the offer, sends the local mic track.
///   • subscriberPC — server creates the offer, we answer; remote audio arrives here.
class VortexWebRTC: NSObject {

    static let shared = VortexWebRTC()
    private override init() {}

    // Callbacks
    var onAudioConnected: (() -> Void)?
    var onError: ((String) -> Void)?

    // WebRTC objects
    private var factory: RTCPeerConnectionFactory?
    private var publisherPC: RTCPeerConnection?
    private var subscriberPC: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var iceServers: [RTCIceServer] = []
    private var isRunning = false
    private var deafened = false
    private var audioConnectedFired = false

    private let localTrackId = "audio0"
    private let localStreamId = "stream0"

    // MARK: - Public API

    func configure(withIceServersRaw raw: [IceServerEntry]) {
        iceServers = raw.map { entry in
            RTCIceServer(urlStrings: entry.urls,
                         username: entry.username,
                         credential: entry.credential)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let sig = VortexSignaling.shared
        sig.onSdpAnswer = { [weak self] type, sdp in
            self?.handlePublisherAnswer(type: type, sdp: sdp)
        }
        sig.onSdpOffer = { [weak self] type, sdp in
            self?.handleSubscriberOffer(type: type, sdp: sdp)
        }
        sig.onRemoteIceTrickle = { [weak self] json, target in
            self?.handleRemoteIce(json: json, target: target)
        }

        RTCInitializeSSL()

        let enc = RTCDefaultVideoEncoderFactory()
        let dec = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: dec)

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        publisherPC  = factory?.peerConnection(with: makeConfig(), constraints: constraints, delegate: self)
        subscriberPC = factory?.peerConnection(with: makeConfig(), constraints: constraints, delegate: self)

        // Local mic track on the publisher.
        let audioSource = factory?.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil))
        if let audioSource = audioSource {
            localAudioTrack = factory?.audioTrack(with: audioSource, trackId: localTrackId)
        }
        if let track = localAudioTrack {
            publisherPC?.add(track, streamIds: [localStreamId])
        }

        // Register the track with the server (so we appear unmuted), then offer.
        VortexSignaling.shared.sendAddTrack(cid: localTrackId, name: "microphone")
        createAndSendPublisherOffer()
    }

    func stop() {
        isRunning = false
        publisherPC?.close();  publisherPC = nil
        subscriberPC?.close(); subscriberPC = nil
        localAudioTrack = nil
        audioConnectedFired = false
        if factory != nil {
            factory = nil
            RTCCleanupSSL()
        }
    }

    private func makeConfig() -> RTCConfiguration {
        let config = RTCConfiguration()
        if iceServers.isEmpty {
            config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        } else {
            config.iceServers = iceServers
        }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        return config
    }

    /// Enable/disable the outgoing mic audio (sends silence when disabled).
    func setMicEnabled(_ enabled: Bool) {
        localAudioTrack?.isEnabled = enabled
    }

    var isMicEnabled: Bool { localAudioTrack?.isEnabled ?? false }

    /// Deafen: stop playing all remote audio (also applies to tracks added later).
    func setDeafened(_ d: Bool) {
        deafened = d
        applyDeafen()
    }

    var isDeafened: Bool { deafened }

    private func applyDeafen() {
        guard let pc = subscriberPC else { return }
        for r in pc.receivers {
            (r.track as? RTCAudioTrack)?.isEnabled = !deafened
        }
    }

    // MARK: - Publisher (we offer)

    private func createAndSendPublisherOffer() {
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false",
                                   "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        publisherPC?.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self = self else { return }
            guard let sdp = sdp, error == nil else {
                self.onError?("offer creation failed: \(error?.localizedDescription ?? "?")")
                return
            }
            self.publisherPC?.setLocalDescription(sdp) { err in
                if let err = err {
                    self.onError?("setLocalDesc(pub): \(err.localizedDescription)")
                    return
                }
                let typeStr = self.sdpTypeString(sdp.type)
                DispatchQueue.main.async {
                    VortexSignaling.shared.sendSdpOffer(type: typeStr, sdp: sdp.sdp)
                }
            }
        }
    }

    private func handlePublisherAnswer(type: String, sdp: String) {
        let remoteSdp = RTCSessionDescription(type: sdpTypeFromString(type), sdp: sdp)
        publisherPC?.setRemoteDescription(remoteSdp) { [weak self] error in
            if let error = error {
                self?.onError?("setRemoteDesc(pub): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Subscriber (server offers, we answer)

    private func handleSubscriberOffer(type: String, sdp: String) {
        guard let sub = subscriberPC else { return }
        let remoteSdp = RTCSessionDescription(type: sdpTypeFromString(type), sdp: sdp)
        sub.setRemoteDescription(remoteSdp) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.onError?("setRemoteDesc(sub): \(error.localizedDescription)")
                return
            }
            let answerConstraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                                        optionalConstraints: nil)
            sub.answer(for: answerConstraints) { sdpAns, err in
                guard let sdpAns = sdpAns, err == nil else {
                    self.onError?("answer creation failed: \(err?.localizedDescription ?? "?")")
                    return
                }
                sub.setLocalDescription(sdpAns) { e in
                    if let e = e {
                        self.onError?("setLocalDesc(sub): \(e.localizedDescription)")
                        return
                    }
                    let typeStr = self.sdpTypeString(sdpAns.type)
                    DispatchQueue.main.async {
                        VortexSignaling.shared.sendSdpAnswer(type: typeStr, sdp: sdpAns.sdp)
                    }
                }
            }
        }
    }

    // MARK: - Remote ICE

    private func handleRemoteIce(json: String, target: Int) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidateStr = dict["candidate"] as? String else { return }
        let sdpMid = dict["sdpMid"] as? String ?? "0"
        let sdpMLineIndex = dict["sdpMLineIndex"] as? Int32 ?? 0
        let candidate = RTCIceCandidate(sdp: candidateStr,
                                         sdpMLineIndex: sdpMLineIndex,
                                         sdpMid: sdpMid)
        // target: 0 = PUBLISHER, 1 = SUBSCRIBER
        if target == 1 { subscriberPC?.add(candidate) }
        else           { publisherPC?.add(candidate) }
    }

    // MARK: - Helpers

    private func sdpTypeString(_ type: RTCSdpType) -> String {
        switch type {
        case .offer:    return "offer"
        case .prAnswer: return "pranswer"
        case .answer:   return "answer"
        default:        return "offer"
        }
    }

    private func sdpTypeFromString(_ s: String) -> RTCSdpType {
        switch s.lowercased() {
        case "answer":   return .answer
        case "pranswer": return .prAnswer
        default:         return .offer
        }
    }

    private func fireAudioConnectedOnce() {
        guard !audioConnectedFired else { return }
        audioConnectedFired = true
        DispatchQueue.main.async { self.onAudioConnected?() }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension VortexWebRTC: RTCPeerConnectionDelegate {

    func peerConnection(_ pc: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        var dict: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex
        ]
        if let mid = candidate.sdpMid { dict["sdpMid"] = mid }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        let target = (pc === subscriberPC) ? 1 : 0
        DispatchQueue.main.async {
            VortexSignaling.shared.sendIceTrickle(json, target: target)
        }
    }

    func peerConnection(_ pc: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        if newState == .connected || newState == .completed {
            fireAudioConnectedOnce()
        } else if newState == .failed {
            DispatchQueue.main.async { self.onError?("ICE connection failed") }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection,
                        didChange newState: RTCPeerConnectionState) {
        if newState == .failed {
            DispatchQueue.main.async { self.onError?("PeerConnection failed") }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // Remote audio arrives on the subscriber PC — honour current deafen state.
        for t in stream.audioTracks { t.isEnabled = !deafened }
        fireAudioConnectedOnce()
    }

    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection,
                        didChange state: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection,
                        didChange state: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection,
                        didOpen channel: RTCDataChannel) {}
}

// MARK: - ICE server entry (raw, no WebRTC dependency)

struct IceServerEntry {
    let urls: [String]
    let username: String
    let credential: String
}
