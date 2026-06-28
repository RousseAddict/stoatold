import Foundation

// Vortex / LiveKit voice WebSocket signaling — Phase 1 (signaling only, no audio).
// Transport: OpenSSL via owsl_bridge (bypasses iOS 6 CBC-only Secure Transport).
//
// Flow:
//   GET  {baseURL}                 → features.livekit.nodes[0].name
//   POST /channels/{id}/join_call  { node } → { token, url }
//   WSS  {url}/rtc?access_token={token}&protocol=7&…
//   → HTTP 101 Switching Protocols
//   → LiveKit sends binary JoinResponse (protobuf) — logged, not yet parsed

struct VortexTransportInfo {
    let ip:              String
    let port:            Int
    let transportId:     String
    let srtpCryptoSuite: String
    let srtpKeyBase64:   String
    let serverRtpCaps:   [String: Any]
    let opusPayloadType: Int
}

class VortexSignaling {

    static let shared = VortexSignaling()
    private init() {}

    // ── Callbacks ─────────────────────────────────────────────────────────────
    var onTransportReady: ((VortexTransportInfo) -> Void)?
    var onDisconnected:   (() -> Void)?
    var onError:          ((String) -> Void)?
    var onUserJoined:     ((String) -> Void)?
    var onUserLeft:       ((String) -> Void)?
    var onUserStartAudio: ((String) -> Void)?
    var onUserStopAudio:  ((String) -> Void)?
    var onParticipants:   (([String]) -> Void)?
    var onConsumerReady:  ((String, String, [String: Any]) -> Void)?
    var onConnected:      (() -> Void)?   // fires when LiveKit JoinResponse arrives
    var onSdpAnswer:      ((String, String) -> Void)?   // (type, sdp) answer → our publisher offer
    var onSdpOffer:       ((String, String) -> Void)?   // (type, sdp) server's subscriber offer
    var onRemoteIceTrickle: ((String, Int) -> Void)?     // (candidateInit JSON, target) from server
    var onIceServersRaw:  (([IceServerEntry]) -> Void)? // ICE servers from JoinResponse

    // ── Private state ─────────────────────────────────────────────────────────
    private var channelId:     String = ""
    private var voiceToken:    String = ""
    private var transportId:   String = ""
    private var serverRtpCaps: [String: Any] = [:]
    private var srtpKey:       [UInt8] = []

    private var pendingIP:    String = ""
    private var pendingPort:  Int    = 0
    private var pendingSuite: String = "AES_CM_128_HMAC_SHA1_80"

    private var owslCtx:      OpaquePointer? = nil   // OWSLContext*
    private var connectedFired = false
    private var readBuffer    = Data()
    private var fragBuffer    = Data()
    private var handshakeDone = false
    private var wsHost        = ""
    private var wsPath        = "/"
    private var pingTimer:    Timer?

    // ── Static C-compatible callbacks ─────────────────────────────────────────
    // Swift closures cannot be passed as C function pointers.
    // Use static funcs + Unmanaged to recover self from userdata.

    private static let owslReadCb: OWSL_read_cb = { buf, len, ud in
        guard let ud = ud, let buf = buf else { return }
        let sig = Unmanaged<VortexSignaling>.fromOpaque(ud).takeUnretainedValue()
        let data = Data(bytes: buf, count: len)
        DispatchQueue.main.async { sig.onRawData(data) }
    }

    private static let owslEventCb: OWSL_event_cb = { kind, msg, ud in
        guard let ud = ud else { return }
        let sig = Unmanaged<VortexSignaling>.fromOpaque(ud).takeUnretainedValue()
        let str = msg.map { String(cString: $0) } ?? ""
        DispatchQueue.main.async { sig.onStreamEvent(kind: Int(kind), msg: str) }
    }

    // ── Public API ────────────────────────────────────────────────────────────

    func joinVoice(channelId: String) {
        guard owslCtx == nil else { return }
        self.channelId = channelId
        fetchVoiceToken()
    }

    func leave() {
        pingTimer?.invalidate(); pingTimer = nil
        if let ctx = owslCtx {
            // Send LiveKit's Leave signal (= web client's room.disconnect()) so the
            // server removes our participant immediately; otherwise the session lingers
            // and the next join_call is rejected with HTTP 400.
            if handshakeDone {
                sendFrame(opcode: 0x2, payload: encodeSignalRequestLeave())
            }
            owsl_close(ctx)
            let q = DispatchQueue(label: "com.stoatold.owsl.destroy")
            q.async { owsl_destroy(ctx) }
            owslCtx = nil
        }
        handshakeDone = false
        readBuffer.removeAll(); fragBuffer.removeAll()
        srtpKey = []
    }

    // ── Phase 1a: get LiveKit node name ───────────────────────────────────────

    private func fetchVoiceToken() {
        guard let token = APIClient.sessionToken else {
            onError?("Not logged in"); return
        }
        HTTPClient.request(
            APIClient.baseURL,
            headers: ["x-session-token": token]
        ) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                self.onError?("server info: \(error.localizedDescription)"); return
            }
            var nodeName: String? = nil
            if let data = data,
               let json  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let feat  = json["features"] as? [String: Any],
               let lk    = feat["livekit"] as? [String: Any],
               let nodes = lk["nodes"] as? [[String: Any]],
               let name  = nodes.first?["name"] as? String {
                nodeName = name
            }
            self.doJoinCall(sessionToken: token, nodeName: nodeName)
        }
    }

    private func doJoinCall(sessionToken: String, nodeName: String?) {
        var bodyDict = [String: Any]()
        if let n = nodeName { bodyDict["node"] = n }
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else { return }
        HTTPClient.request(
            "\(APIClient.baseURL)/channels/\(channelId)/join_call",
            method: "POST",
            headers: ["x-session-token": sessionToken],
            body: body
        ) { [weak self] data, status, error in
            guard let self = self else { return }
            if let error = error {
                self.onError?("join_call: \(error.localizedDescription)"); return
            }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tok  = json["token"] as? String,
                  let url  = json["url"]   as? String else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                self.onError?("join_call HTTP \(status): \(body.prefix(160))"); return
            }
            self.voiceToken = tok
            // OpenSSL supports GCM — use wss:// (TLS)
            var wsURL = url
            if !wsURL.hasPrefix("ws") {
                wsURL = wsURL
                    .replacingOccurrences(of: "https://", with: "wss://")
                    .replacingOccurrences(of: "http://",  with: "ws://")
            }
            self.openWebSocket(to: wsURL)
        }
    }

    // ── WebSocket connect via OpenSSL ─────────────────────────────────────────

    private func openWebSocket(to urlString: String) {
        guard let url  = URL(string: urlString),
              let host = url.host else {
            onError?("invalid LiveKit URL: \(urlString)"); return
        }
        let useTLS = url.scheme == "wss"
        let port   = url.port ?? (useTLS ? 443 : 80)
        wsHost = host

        let basePath = url.path.isEmpty ? "" : url.path
        let encodedToken = voiceToken
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "=", with: "%3D")
        wsPath = "\(basePath)/rtc?access_token=\(encodedToken)&protocol=7&auto_subscribe=1&sdk=js"

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = owsl_create(host, CInt(port),
                                    VortexSignaling.owslReadCb,
                                    VortexSignaling.owslEventCb,
                                    selfPtr) else {
            onError?("owsl_create failed"); return
        }
        owslCtx = ctx

        DispatchQueue(label: "com.stoatold.owsl.connect").async { [weak self] in
            guard let self = self else { return }
            let ret = owsl_connect(ctx)
            DispatchQueue.main.async {
                guard self.owslCtx != nil else { return }
                if ret != 0 {
                    let errStr = String(cString: owsl_last_error(ctx))
                    self.onError?("TLS connect failed (\(ret)): \(errStr)")
                    return
                }
                owsl_start_reading(ctx)
                self.sendHandshake()
            }
        }
    }

    // ── Data / event callbacks (main thread) ──────────────────────────────────

    private func onRawData(_ data: Data) {
        readBuffer.append(data)
        if handshakeDone { processFrames() } else { processHandshake() }
    }

    private func onStreamEvent(kind: Int, msg: String) {
        switch kind {
        case 1:  leave(); onDisconnected?()
        case 2:  leave(); onError?("stream error: \(msg)")
        default: break
        }
    }

    // ── HTTP upgrade ──────────────────────────────────────────────────────────

    private func sendHandshake() {
        let key = generateKey()
        let req = "GET \(wsPath) HTTP/1.1\r\n"
                + "Host: \(wsHost)\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(key)\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "\r\n"
        writeRaw(req.data(using: .utf8)!)
    }

    private func processHandshake() {
        let cr: UInt8 = 0x0D, lf: UInt8 = 0x0A
        var headerEnd: Int? = nil
        if readBuffer.count >= 4 {
            for i in 0...(readBuffer.count - 4) {
                if readBuffer[i]   == cr && readBuffer[i+1] == lf
                && readBuffer[i+2] == cr && readBuffer[i+3] == lf {
                    headerEnd = i + 4; break
                }
            }
        }
        guard let end = headerEnd else { return }

        let headerData = Data(readBuffer.prefix(end))
        guard let headerStr = String(data: headerData, encoding: .utf8),
              headerStr.contains("101") else {
            let preview = String(data: Data(readBuffer.prefix(120)), encoding: .utf8) ?? "(binary)"
            leave()
            onError?("WS handshake rejected — path: \(wsPath.prefix(60)) response: \(preview)")
            return
        }

        readBuffer    = Data(readBuffer.dropFirst(end))
        handshakeDone = true
        onError?("101 OK — waiting for LiveKit response")

        let t = Timer(timeInterval: 10, target: self,
                      selector: #selector(sendPing), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pingTimer = t

        if !readBuffer.isEmpty { processFrames() }
    }

    // LiveKit (/rtc protocol 7) keeps the session alive via an application-level
    // SignalRequest.ping; it ignores text frames, so a JSON "Ping" never resets the
    // server's timeout and the room is torn down after ~1 min. Send a real protobuf
    // ping as a binary frame; the server replies with pong and the session stays open.
    @objc private func sendPing() {
        guard handshakeDone, owslCtx != nil else { return }
        // Send both the legacy int64 ping (field 14) and the newer Ping message
        // (ping_req, field 16) in separate frames — different LiveKit server versions
        // honour one or the other; whichever resets the session timeout keeps us alive.
        sendFrame(opcode: 0x2, payload: encodeSignalRequestPing())
        sendFrame(opcode: 0x2, payload: encodeSignalRequestPingReq())
    }

    // ── Signaling helpers ─────────────────────────────────────────────────────

    private func sendAuthenticate() {
        sendCmd("Authenticate", data: ["roomId": channelId, "token": voiceToken])
    }

    private func sendInitializeTransports() {
        let opusCaps: [String: Any] = [
            "codecs": [["mimeType": "audio/opus", "kind": "audio", "clockRate": 48000,
                        "channels": 2, "parameters": [String: Any](),
                        "preferredPayloadType": 111] as [String: Any]] as [[String: Any]],
            "headerExtensions": [[String: Any]]()
        ]
        sendCmd("InitializeTransports", data: ["mode": "CombinedRtp", "rtpCapabilities": opusCaps])
    }

    private func sendConnectTransport() {
        var key = [UInt8](repeating: 0, count: 30)
        for i in 0..<30 { key[i] = UInt8(arc4random_uniform(256)) }
        srtpKey = key
        sendCmd("ConnectTransport", data: [
            "id": transportId,
            "srtpParameters": ["cryptoSuite": "AES_CM_128_HMAC_SHA1_80",
                                "keyBase64":   b64encode(key)] as [String: Any]
        ])
    }

    // ── Message dispatch ──────────────────────────────────────────────────────

    private func deliver(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type    = json["type"] as? String ?? ""
        let payload = json["data"] as? [String: Any] ?? [:]

        switch type {
        case "Authenticated":
            serverRtpCaps = payload["rtpCapabilities"] as? [String: Any] ?? [:]
            sendInitializeTransports()

        case "TransportsInitialized":
            transportId = payload["id"]   as? String ?? ""
            let ip      = payload["ip"]   as? String ?? ""
            let port    = payload["port"] as? Int    ?? 0
            let suite   = payload["srtpCryptoSuite"] as? String
                       ?? payload["srtp_crypto_suite"] as? String
                       ?? "AES_CM_128_HMAC_SHA1_80"
            guard !transportId.isEmpty, !ip.isEmpty, port > 0 else {
                onError?("TransportsInitialized: missing ip/port/id"); return
            }
            pendingIP = ip; pendingPort = port; pendingSuite = suite
            sendConnectTransport()

        case "ConnectedTransport":
            let info = VortexTransportInfo(
                ip: pendingIP, port: pendingPort, transportId: transportId,
                srtpCryptoSuite: pendingSuite, srtpKeyBase64: b64encode(srtpKey),
                serverRtpCaps: serverRtpCaps, opusPayloadType: opusPayloadType(from: serverRtpCaps))
            onTransportReady?(info)

        case "UserJoined":
            if let u = payload["id"] as? String ?? payload["userId"] as? String { onUserJoined?(u) }

        case "UserLeft":
            if let u = payload["id"] as? String ?? payload["userId"] as? String { onUserLeft?(u) }

        case "UserStartProduce":
            if let u = payload["userId"] as? String ?? payload["id"] as? String { onUserStartAudio?(u) }

        case "UserStopProduce":
            if let u = payload["userId"] as? String ?? payload["id"] as? String { onUserStopAudio?(u) }

        case "RoomInfo":
            let users = (payload["users"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String ?? $0["userId"] as? String }
            onParticipants?(users)

        case "ConsumerReady":
            let cid = payload["id"]            as? String ?? ""
            let uid = payload["userId"]        as? String ?? ""
            let rtp = payload["rtpParameters"] as? [String: Any] ?? [:]
            if !cid.isEmpty { onConsumerReady?(cid, uid, rtp) }

        default: break
        }
    }

    // ── Public signaling (Phase 2+) ───────────────────────────────────────────

    func sendStartProduce(rtpParameters: [String: Any]) {
        sendCmd("StartProduce", data: ["type": "audio", "rtpParameters": rtpParameters])
    }
    func sendStopProduce()                   { sendCmd("StopProduce", data: ["type": "audio"]) }
    func sendStartConsume(userId: String)    { sendCmd("StartConsume", data: ["userId": userId, "type": "audio"]) }
    func sendStopConsume(consumerId: String) { sendCmd("StopConsume", data: ["id": consumerId]) }
    func requestRoomInfo()                   { sendCmd("RoomInfo") }

    // ── WebRTC SDP / ICE send ─────────────────────────────────────────────────

    func sendSdpOffer(type: String, sdp: String) {
        let payload = encodeSignalRequestOffer(type: type, sdp: sdp)
        sendFrame(opcode: 0x2, payload: payload)   // binary frame
    }

    func sendSdpAnswer(type: String, sdp: String) {
        let payload = encodeSignalRequestAnswer(type: type, sdp: sdp)
        sendFrame(opcode: 0x2, payload: payload)   // binary frame — subscriber answer
    }

    // Register the published mic track so the server marks us unmuted with a real audio source.
    func sendAddTrack(cid: String, name: String) {
        let payload = encodeSignalRequestAddTrack(cid: cid, name: name)
        sendFrame(opcode: 0x2, payload: payload)   // binary frame
    }

    // target: 0 = PUBLISHER, 1 = SUBSCRIBER
    func sendIceTrickle(_ candidateJson: String, target: Int) {
        let payload = encodeSignalRequestTrickle(candidateJson: candidateJson, target: target)
        sendFrame(opcode: 0x2, payload: payload)   // binary frame
    }

    // ── Send helpers ──────────────────────────────────────────────────────────

    private func sendCmd(_ type: String, data: [String: Any]? = nil) {
        var msg: [String: Any] = ["type": type]
        if let d = data { msg["data"] = d }
        guard let bytes = try? JSONSerialization.data(withJSONObject: msg) else { return }
        sendFrame(opcode: 0x1, payload: bytes)
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data()
        frame.append(0x80 | opcode)
        let mask: [UInt8] = [UInt8(arc4random_uniform(256)), UInt8(arc4random_uniform(256)),
                             UInt8(arc4random_uniform(256)), UInt8(arc4random_uniform(256))]
        let len = payload.count
        if len < 126 {
            frame.append(0x80 | UInt8(len))
        } else {
            frame.append(0x80 | 126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        }
        frame.append(contentsOf: mask)
        var masked = payload
        for i in 0..<masked.count { masked[i] ^= mask[i % 4] }
        frame.append(masked)
        writeRaw(frame)
    }

    private func writeRaw(_ data: Data) {
        guard let ctx = owslCtx else { return }
        data.withUnsafeBytes { ptr in
            _ = owsl_write(ctx, ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count)
        }
    }

    // ── Frame parsing (RFC 6455) ──────────────────────────────────────────────

    private func processFrames() {
        while true {
            guard readBuffer.count >= 2 else { return }
            let b0 = readBuffer[0], b1 = readBuffer[1]
            let fin     = (b0 & 0x80) != 0
            let opcode  = b0 & 0x0F
            let masked  = (b1 & 0x80) != 0
            let lenByte = Int(b1 & 0x7F)

            var hdrEnd = 2
            var payLen: Int
            if lenByte < 126 {
                payLen = lenByte
            } else if lenByte == 126 {
                guard readBuffer.count >= 4 else { return }
                payLen = Int(readBuffer[2]) << 8 | Int(readBuffer[3])
                hdrEnd = 4
            } else {
                guard readBuffer.count >= 10 else { return }
                var len64: UInt64 = 0
                for i in 2..<10 { len64 = (len64 << 8) | UInt64(readBuffer[i]) }
                guard len64 <= UInt64(Int.max) else { leave(); return }
                payLen = Int(len64)
                hdrEnd = 10
            }

            var maskKey: [UInt8]?
            if masked {
                guard readBuffer.count >= hdrEnd + 4 else { return }
                maskKey = [readBuffer[hdrEnd], readBuffer[hdrEnd+1],
                           readBuffer[hdrEnd+2], readBuffer[hdrEnd+3]]
                hdrEnd += 4
            }

            let total = hdrEnd + payLen
            guard payLen >= 0, total >= hdrEnd, readBuffer.count >= total else { return }

            var payload = readBuffer.subdata(in: hdrEnd..<total)
            if let mask = maskKey { for i in 0..<payload.count { payload[i] ^= mask[i % 4] } }
            readBuffer = Data(readBuffer.dropFirst(total))

            switch opcode {
            case 0x0:
                fragBuffer.append(payload)
                if fin { deliver(fragBuffer); fragBuffer = Data() }
            case 0x1:
                if fin { deliver(payload) } else { fragBuffer = payload }
            case 0x2:  // binary — LiveKit SignalResponse (protobuf)
                parseLiveKitSignal(payload)
                if !connectedFired { connectedFired = true; onConnected?() }            case 0x8:
                let code   = payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : -1
                let reason = payload.count > 2
                    ? (String(data: Data(payload[2...]), encoding: .utf8) ?? "(binary)") : ""
                onError?("server closed: \(code) \(reason)")
                leave()
            case 0x9:
                sendFrame(opcode: 0xA, payload: payload)
            default:
                break
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func opusPayloadType(from caps: [String: Any]) -> Int {
        for codec in caps["codecs"] as? [[String: Any]] ?? [] {
            let mime = (codec["mimeType"] as? String ?? "").lowercased()
            if mime == "audio/opus" || mime.hasSuffix("/opus") {
                return codec["preferredPayloadType"] as? Int ?? codec["payloadType"] as? Int ?? 111
            }
        }
        return 111
    }

    private static let b64chars = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    private func b64encode(_ bytes: [UInt8]) -> String {
        var out = ""; var i = 0
        while i < bytes.count {
            let b0 = bytes[i]
            let b1 = i+1 < bytes.count ? bytes[i+1] : 0
            let b2 = i+2 < bytes.count ? bytes[i+2] : 0
            out.append(VortexSignaling.b64chars[Int(b0 >> 2)])
            out.append(VortexSignaling.b64chars[Int((b0 & 3) << 4 | b1 >> 4)])
            out.append(i+1 < bytes.count ? VortexSignaling.b64chars[Int((b1 & 15) << 2 | b2 >> 6)] : "=")
            out.append(i+2 < bytes.count ? VortexSignaling.b64chars[Int(b2 & 63)] : "=")
            i += 3
        }
        return out
    }

    private func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = UInt8(arc4random_uniform(256)) }
        return b64encode(bytes)
    }

    // ── LiveKit Protobuf Parsing ──────────────────────────────────────────────
    // Minimal decoder — only the fields we need. No dependency on libprotobuf.

    private func parseLiveKitSignal(_ data: Data) {
        var r = ProtoReader(data)
        while r.hasMore {
            guard let (field, wt) = r.readTag() else { break }
            if wt == 2, let bytes = r.readBytes() {
                switch field {
                case 1: parseJoinResponse(bytes)       // JoinResponse
                case 2: parseSessionDescAnswer(bytes)  // SessionDescription answer → our publisher offer
                case 3: parseSessionDescOffer(bytes)   // SessionDescription offer → server subscriber offer
                case 4: parseTrickleResponse(bytes)    // TrickleRequest (ICE)
                case 5: parseParticipantUpdate(bytes)  // ParticipantUpdate
                default: break
                }
            } else { r.skip(wireType: wt) }
        }
    }

    private func parseJoinResponse(_ data: Data) {
        var r = ProtoReader(data)
        var participants: [String] = []
        var iceEntries: [IceServerEntry] = []
        while r.hasMore {
            guard let (field, wt) = r.readTag() else { break }
            if wt == 2, let bytes = r.readBytes() {
                switch field {
                case 3:   // other_participants (repeated ParticipantInfo)
                    let p = parseParticipantInfo(bytes)
                    let display = p.name.isEmpty ? p.identity : p.name
                    if !display.isEmpty { participants.append(display) }
                case 5:   // ice_servers (repeated ICEServer)
                    if let entry = parseIceServer(bytes) { iceEntries.append(entry) }
                default: break
                }
            } else { r.skip(wireType: wt) }
        }
        onParticipants?(participants)
        if !iceEntries.isEmpty { onIceServersRaw?(iceEntries) }
    }

    // ICEServer: field 1 = urls (repeated string), field 2 = username, field 3 = credential
    private func parseIceServer(_ data: Data) -> IceServerEntry? {
        var r = ProtoReader(data)
        var urls: [String] = []; var username = ""; var credential = ""
        while r.hasMore {
            guard let (field, wt) = r.readTag() else { break }
            if wt == 2, let bytes = r.readBytes() {
                switch field {
                case 1: urls.append(String(data: bytes, encoding: .utf8) ?? "")
                case 2: username   = String(data: bytes, encoding: .utf8) ?? ""
                case 3: credential = String(data: bytes, encoding: .utf8) ?? ""
                default: break
                }
            } else { r.skip(wireType: wt) }
        }
        return urls.isEmpty ? nil : IceServerEntry(urls: urls, username: username, credential: credential)
    }

    // SessionDescription answer from server: field 1 = type, field 2 = sdp
    private func parseSessionDescAnswer(_ data: Data) {
        var r = ProtoReader(data)
        var type = ""; var sdp = ""
        while r.hasMore {
            guard let (field, wt) = r.readTag() else { break }
            if wt == 2, let bytes = r.readBytes() {
                switch field {
                case 1: type = String(data: bytes, encoding: .utf8) ?? ""
                case 2: sdp  = String(data: bytes, encoding: .utf8) ?? ""
                default: break
                }
            } else { r.skip(wireType: wt) }
        }
        if !sdp.isEmpty { onSdpAnswer?(type.isEmpty ? "answer" : type, sdp) }
    }

    // SessionDescription offer from server (subscriber PC): field 1 = type, field 2 = sdp
    private func parseSessionDescOffer(_ data: Data) {
        var r = ProtoReader(data)
        var type = ""; var sdp = ""
        while r.hasMore {
            guard let (field, wt) = r.readTag() else { break }
            if wt == 2, let bytes = r.readBytes() {
                switch field {
                case 1: type = String(data: bytes, encoding: .utf8) ?? ""
                case 2: sdp  = String(data: bytes, encoding: .utf8) ?? ""
                default: break
                }
            } else { r.skip(wireType: wt) }
        }
        if !sdp.isEmpty { onSdpOffer?(type.isEmpty ? "offer" : type, sdp) }
    }

    // TrickleRequest from server: field 1 = candidateInit JSON, field 2 = target (0=PUB,1=SUB)
    private func parseTrickleResponse(_ data: Data) {
        var r = ProtoReader(data)
        var json: String? = nil; var target = 0
        while r.hasMore {
            guard let (field, wt) = r.readTag() else { break }
            switch (field, wt) {
            case (1, 2):
                if let b = r.readBytes() { json = String(data: b, encoding: .utf8) }
            case (2, 0):
                if let v = r.readVarint() { target = Int(v) }
            default:
                r.skip(wireType: wt)
            }
        }
        if let json = json { onRemoteIceTrickle?(json, target) }
    }

    private func parseParticipantUpdate(_ data: Data) {
        // ParticipantUpdate.participants (field 1, repeated ParticipantInfo)
        var r = ProtoReader(data)
        while r.hasMore {
            guard let (field, wt) = r.readTag() else { break }
            if wt == 2, let bytes = r.readBytes() {
                if field == 1 {
                    let p = parseParticipantInfo(bytes)
                    let display = p.name.isEmpty ? p.identity : p.name
                    if display.isEmpty { continue }
                    if p.state == 3 { onUserLeft?(display) }  // DISCONNECTED
                    else             { onUserJoined?(display) }
                }
            } else { r.skip(wireType: wt) }
        }
    }

    // Returns (identity, name, state) from a ParticipantInfo message.
    // state: 0=JOINING 1=JOINED 2=ACTIVE 3=DISCONNECTED
    private func parseParticipantInfo(_ data: Data) -> (identity: String, name: String, state: Int) {
        var r = ProtoReader(data)
        var identity = ""; var name = ""; var state = 0
        while r.hasMore {
            guard let (field, wt) = r.readTag() else { break }
            switch (field, wt) {
            case (2, 2):  // identity (string)
                if let b = r.readBytes() { identity = String(data: b, encoding: .utf8) ?? "" }
            case (3, 0):  // state (varint)
                if let v = r.readVarint() { state = Int(v) }
            case (7, 2):  // name (string)
                if let b = r.readBytes() { name = String(data: b, encoding: .utf8) ?? "" }
            default:
                r.skip(wireType: wt)
            }
        }
        return (identity, name, state)
    }
}

// ── Minimal protobuf binary encoder ──────────────────────────────────────────

private func encodeVarint(_ v: UInt64) -> [UInt8] {
    var result = [UInt8](); var val = v
    repeat { result.append(UInt8((val & 0x7F) | (val > 127 ? 0x80 : 0))); val >>= 7 } while val > 0
    return result
}

private func protoStringField(_ fieldNo: Int, _ s: String) -> [UInt8] {
    let bytes = Array(s.utf8)
    let tag   = encodeVarint(UInt64((fieldNo << 3) | 2))
    return tag + encodeVarint(UInt64(bytes.count)) + bytes
}

private func protoMessageField(_ fieldNo: Int, _ body: [UInt8]) -> [UInt8] {
    let tag = encodeVarint(UInt64((fieldNo << 3) | 2))
    return tag + encodeVarint(UInt64(body.count)) + body
}

private func protoVarintField(_ fieldNo: Int, _ v: UInt64) -> [UInt8] {
    let tag = encodeVarint(UInt64((fieldNo << 3) | 0))
    return tag + encodeVarint(v)
}

// SignalRequest { offer (field 1) = SessionDescription { type(1), sdp(2) } } — publisher.
private func encodeSignalRequestOffer(type: String, sdp: String) -> Data {
    let sdpMsg: [UInt8] = protoStringField(1, type) + protoStringField(2, sdp)
    return Data(protoMessageField(1, sdpMsg))
}

// SignalRequest { answer (field 2) = SessionDescription { type(1), sdp(2) } } — subscriber.
private func encodeSignalRequestAnswer(type: String, sdp: String) -> Data {
    let sdpMsg: [UInt8] = protoStringField(1, type) + protoStringField(2, sdp)
    return Data(protoMessageField(2, sdpMsg))
}

// SignalRequest { add_track (field 4) = AddTrackRequest {
//   cid(1), name(2), type(3)=AUDIO(0), source(8)=MICROPHONE(2) } }
// muted (field 6) is omitted → proto3 default false → server marks the track unmuted.
private func encodeSignalRequestAddTrack(cid: String, name: String) -> Data {
    var body: [UInt8] = protoStringField(1, cid) + protoStringField(2, name)
    body += protoVarintField(3, 0)   // TrackType.AUDIO
    body += protoVarintField(8, 2)   // TrackSource.MICROPHONE
    return Data(protoMessageField(4, body))
}

// SignalRequest { ping (field 14, int64) = unix millis } — LiveKit keepalive (legacy).
private func encodeSignalRequestPing() -> Data {
    let millis = UInt64(Date().timeIntervalSince1970 * 1000)
    return Data(protoVarintField(14, millis))
}

// SignalRequest { ping_req (field 16) = Ping { timestamp(1)=unix millis, rtt(2)=0 } } — newer.
private func encodeSignalRequestPingReq() -> Data {
    let millis = UInt64(Date().timeIntervalSince1970 * 1000)
    let ping: [UInt8] = protoVarintField(1, millis) + protoVarintField(2, 0)
    return Data(protoMessageField(16, ping))
}

// SignalRequest { trickle (field 3) = TrickleRequest { candidateInit(1), target(2) } }
// target: 0 = PUBLISHER, 1 = SUBSCRIBER
private func encodeSignalRequestTrickle(candidateJson: String, target: Int) -> Data {
    var trickle: [UInt8] = protoStringField(1, candidateJson)
    trickle += protoVarintField(2, UInt64(target))
    return Data(protoMessageField(3, trickle))
}

// SignalRequest { leave (field 8) = LeaveRequest { reason(2) = CLIENT_INITIATED(1) } }
// Equivalent of the web client's room.disconnect() — tells the server to cleanly remove
// our participant so a subsequent join_call doesn't 400 on a ghost session.
private func encodeSignalRequestLeave() -> Data {
    let leave: [UInt8] = protoVarintField(2, 1)   // DisconnectReason.CLIENT_INITIATED
    return Data(protoMessageField(8, leave))
}

// ── Minimal protobuf binary reader ────────────────────────────────────────────

private struct ProtoReader {
    private let data: Data
    private var pos:  Int = 0

    init(_ data: Data) { self.data = data }

    var hasMore: Bool { pos < data.count }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0; var shift = 0
        while pos < data.count {
            let b = UInt64(data[pos]); pos += 1
            result |= (b & 0x7F) << UInt64(shift)
            if (b & 0x80) == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    mutating func readBytes() -> Data? {
        guard let len = readVarint(), len <= UInt64(data.count - pos) else { return nil }
        let n = Int(len); let bytes = data.subdata(in: pos..<pos+n); pos += n
        return bytes
    }

    mutating func skip(wireType: Int) {
        switch wireType {
        case 0: _ = readVarint()
        case 1: pos = min(pos + 8,  data.count)
        case 2: _ = readBytes()
        case 5: pos = min(pos + 4,  data.count)
        default: pos = data.count
        }
    }

    mutating func readTag() -> (field: Int, wireType: Int)? {
        guard let tag = readVarint() else { return nil }
        return (Int(tag >> 3), Int(tag & 0x7))
    }
}
