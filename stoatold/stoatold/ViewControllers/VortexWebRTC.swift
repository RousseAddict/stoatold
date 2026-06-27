import UIKit
import WebRTC

/// Manages WebRTC peer connection for LiveKit voice rooms.
/// Lifecycle:
///   1. VortexSignaling connects and fires onIceServersRaw
///   2. Call configure(withIceServersRaw:) then start()
///   3. start() creates offer → sends via VortexSignaling
///   4. VortexSignaling delivers answer → peerConnection connects
///   5. ICE candidates flow in both directions automatically
class VortexWebRTC: NSObject {

    static let shared = VortexWebRTC()
    private override init() {}

    // Callbacks
    var onAudioConnected: (() -> Void)?
    var onError: ((String) -> Void)?

    // WebRTC objects
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var iceServers: [RTCIceServer] = []
    private var isRunning = false

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
            self?.handleAnswer(type: type, sdp: sdp)
        }
        sig.onRemoteIceTrickle = { [weak self] json in
            self?.handleRemoteIce(json: json)
        }

        RTCInitializeSSL()
        setupPeerConnection()
        createAndSendOffer()
    }

    func stop() {
        isRunning = false
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        if factory != nil {
            factory = nil
            RTCCleanupSSL()
        }
    }

    // MARK: - Setup

    private func setupPeerConnection() {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory,
                                           decoderFactory: decoderFactory)

        let config = RTCConfiguration()
        if iceServers.isEmpty {
            config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        } else {
            config.iceServers = iceServers
        }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: nil)
        peerConnection = factory?.peerConnection(with: config,
                                                  constraints: constraints,
                                                  delegate: self)

        // Add local audio track (microphone input)
        let audioSource = factory?.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil))
        if let source = audioSource {
            localAudioTrack = factory?.audioTrack(with: source, trackId: "audio0")
            if let track = localAudioTrack {
                peerConnection?.add(track, streamIds: ["stream0"])
            }
        }
    }

    private func createAndSendOffer() {
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true",
                                   "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        peerConnection?.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self = self else { return }
            guard let sdp = sdp, error == nil else {
                self.onError?("offer creation failed: \(error?.localizedDescription ?? "?")")
                return
            }
            self.peerConnection?.setLocalDescription(sdp) { err in
                if let err = err {
                    self.onError?("setLocalDesc: \(err.localizedDescription)")
                    return
                }
                let typeStr = self.sdpTypeString(sdp.type)
                DispatchQueue.main.async {
                    VortexSignaling.shared.sendSdpOffer(type: typeStr, sdp: sdp.sdp)
                }
            }
        }
    }

    // MARK: - Remote SDP / ICE handling

    private func handleAnswer(type: String, sdp: String) {
        let sdpType = sdpTypeFromString(type)
        let remoteSdp = RTCSessionDescription(type: sdpType, sdp: sdp)
        peerConnection?.setRemoteDescription(remoteSdp) { [weak self] error in
            if let error = error {
                self?.onError?("setRemoteDesc: \(error.localizedDescription)")
            }
        }
    }

    private func handleRemoteIce(json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidateStr = dict["candidate"] as? String else { return }
        let sdpMid = dict["sdpMid"] as? String ?? "0"
        let sdpMLineIndex = dict["sdpMLineIndex"] as? Int32 ?? 0
        let candidate = RTCIceCandidate(sdp: candidateStr,
                                         sdpMLineIndex: sdpMLineIndex,
                                         sdpMid: sdpMid)
        peerConnection?.add(candidate)
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
}

// MARK: - RTCPeerConnectionDelegate

extension VortexWebRTC: RTCPeerConnectionDelegate {

    func peerConnection(_ pc: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        // Build standard browser-compatible ICE candidate JSON
        var dict: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex
        ]
        if let mid = candidate.sdpMid { dict["sdpMid"] = mid }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            VortexSignaling.shared.sendIceTrickle(json)
        }
    }

    func peerConnection(_ pc: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        if newState == .connected || newState == .completed {
            DispatchQueue.main.async { self.onAudioConnected?() }
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

    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection,
                        didChange state: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
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
