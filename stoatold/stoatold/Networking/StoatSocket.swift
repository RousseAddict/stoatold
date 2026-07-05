import Foundation
import UIKit

// Minimal RFC 6455 WebSocket for iOS 6.
// Uses CFStreamCreatePairWithSocketToHost + SSL — no URLSession (iOS 7+).
// Mirrors the React StoatSocket: Authenticate on connect, Ping every 30s.
class StoatSocket: NSObject, StreamDelegate {

    static let shared = StoatSocket()
    private override init() {}

    // ── Parsed data from Ready event ─────────────────────────────────────────
    private(set) var servers:     [StoatServer]          = []
    private(set) var allChannels: [String: StoatChannel] = [:]  // id → channel
    var dmChannels: [StoatChannel] { return allChannels.values.filter { $0.isDirect }.sorted { $0.id < $1.id } }
    var pendingFriendRequests: [StoatUser] { return allUsers.values.filter { $0.relationship == "Incoming" } }
    private(set) var currentUser: StoatUser?
    private(set) var allUsers: [String: StoatUser] = [:]
    var activeChannelId: String?                          // set by ChatVC while open
    private(set) var unreadChannelIds: Set<String> = []  // channels with pending unreads
    var onNewMessage: ((String) -> Void)?                 // called with channelId on new msg
    var onNewChannel: (() -> Void)?                       // called when a new DM channel is cached
    var onUnreadsChanged: (() -> Void)?                   // called after /sync/unreads recomputes unreads

    // ── Callbacks ─────────────────────────────────────────────────────────────
    var onReady:      (() -> Void)?
    var onEvent:      (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    // ── Private state ─────────────────────────────────────────────────────────
    private var inputStream:  InputStream?
    private var outputStream: OutputStream?
    private var readBuffer    = Data()
    private var writeBuffer   = Data()
    private var fragBuffer    = Data()
    private var handshakeDone = false
    private var token:        String?
    private var pingTimer:    Timer?
    private var _host = ""
    private var _path = "/"
    private var reconnectURL   = ""
    private var reconnectDelay: TimeInterval = 3
    private var reconnectTimer: Timer?

    // ── Connect ───────────────────────────────────────────────────────────────

    func connect(urlString: String, token: String) {
        guard inputStream == nil else { return }  // already connected
        self.token = token
        reconnectURL   = urlString
        reconnectDelay = 3
        reconnectTimer?.invalidate(); reconnectTimer = nil

        guard let url  = URL(string: urlString),
              let host = url.host else { return }
        let port = url.port ?? (url.scheme == "wss" ? 443 : 80)
        _host = host
        _path = url.path.isEmpty ? "/" : url.path

        var readRef:  Unmanaged<CFReadStream>?
        var writeRef: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString,
                                           UInt32(port), &readRef, &writeRef)
        guard let r = readRef?.takeRetainedValue(),
              let w = writeRef?.takeRetainedValue() else { return }

        if url.scheme == "wss" {
            // Use CF API directly so kCFStreamPropertySSLSettings is matched by pointer,
            // not by string — NSStream bridge may create a new string and miss the lookup.
            let sslKey = CFStreamPropertyKey(kCFStreamPropertySSLSettings)
            let sslDict: CFDictionary = [
                kCFStreamSSLValidatesCertificateChain: kCFBooleanFalse!,
                kCFStreamSSLLevel: kCFStreamSocketSecurityLevelNegotiatedSSL
            ] as CFDictionary
            CFReadStreamSetProperty(r,  sslKey, sslDict)
            CFWriteStreamSetProperty(w, sslKey, sslDict)
        }

        let input  = r as InputStream
        let output = w as OutputStream
        input.delegate  = self
        output.delegate = self
        input.schedule(in:  .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        inputStream  = input
        outputStream = output
        StoatDebug.log("socket: streams opened to \(_host)")
        input.open()
        output.open()
    }

    // ── Disconnect ────────────────────────────────────────────────────────────

    func disconnect(intentional: Bool = false) {
        reconnectTimer?.invalidate(); reconnectTimer = nil
        if intentional { reconnectURL = "" }
        pingTimer?.invalidate(); pingTimer = nil
        inputStream?.remove(from:  .main, forMode: .common); inputStream?.close()
        outputStream?.remove(from: .main, forMode: .common); outputStream?.close()
        inputStream  = nil
        outputStream = nil
        handshakeDone = false
        readBuffer.removeAll(); writeBuffer.removeAll(); fragBuffer.removeAll()
        allUsers.removeAll()
        unreadChannelIds.removeAll()
        currentUser = nil
        if !intentional && !reconnectURL.isEmpty {
            onDisconnect?()
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        StoatDebug.log("socket: reconnect in \(Int(reconnectDelay))s")
        let t = Timer(timeInterval: reconnectDelay, target: self,
                      selector: #selector(attemptReconnect), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        reconnectTimer = t
        reconnectDelay = min(reconnectDelay * 2, 30)
    }

    @objc private func attemptReconnect() {
        guard let tok = token, !reconnectURL.isEmpty else { return }
        StoatDebug.log("socket: reconnecting to \(reconnectURL)")
        connect(urlString: reconnectURL, token: tok)
    }

    // ── Send ──────────────────────────────────────────────────────────────────

    func cacheUser(_ user: StoatUser) { allUsers[user.id] = user }
    func cacheChannel(_ ch: StoatChannel) { allChannels[ch.id] = ch }
    func markRead(_ channelId: String) { unreadChannelIds.remove(channelId); updateBadge() }

    func updateBadge() {
        let count = unreadChannelIds.count + pendingFriendRequests.count
        UIApplication.shared.applicationIconBadgeNumber = count
    }

    // Seed unread state at launch from the server's persisted read receipts.
    // A channel is unread when its last_message_id is newer (ULIDs sort lexicographically
    // by time) than the last_id we've read. Channels with no read record are left alone
    // to avoid flagging every never-opened channel on first launch.
    private func fetchUnreads() {
        guard let tok = token else { return }
        HTTPClient.request("\(APIClient.baseURL)/sync/unreads", method: "GET",
                           headers: ["x-session-token": tok]) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { return }
            var lastRead: [String: String] = [:]
            for u in arr {
                if let idObj = u["_id"] as? [String: Any],
                   let chId  = idObj["channel"] as? String {
                    lastRead[chId] = u["last_id"] as? String
                }
            }
            for (chId, ch) in self.allChannels {
                guard ch.isText || ch.isDirect, chId != self.activeChannelId,
                      let lastMsg = ch.lastMessageId else { continue }
                if let readId = lastRead[chId], lastMsg > readId {
                    self.unreadChannelIds.insert(chId)
                }
            }
            self.updateBadge()
            self.onUnreadsChanged?()
        }
    }

    private func fetchAndCacheChannel(_ id: String) {
        guard let tok = token else { return }
        HTTPClient.request("\(APIClient.baseURL)/channels/\(id)", method: "GET",
                           headers: ["x-session-token": tok]) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ch   = StoatChannel.from(dict: dict) else { return }
            self.allChannels[ch.id] = ch
            self.onNewChannel?()
        }
    }

    func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        sendFrame(opcode: 0x1, payload: data)
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data()
        frame.append(0x80 | opcode)
        let mask: [UInt8] = [UInt8(arc4random_uniform(256)),
                             UInt8(arc4random_uniform(256)),
                             UInt8(arc4random_uniform(256)),
                             UInt8(arc4random_uniform(256))]
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
        writeBuffer.append(data)
        flushWrite()
    }

    private func flushWrite() {
        guard let out = outputStream, out.hasSpaceAvailable,
              !writeBuffer.isEmpty else { return }
        let n = writeBuffer.withUnsafeBytes {
            out.write($0.baseAddress!.assumingMemoryBound(to: UInt8.self),
                      maxLength: writeBuffer.count)
        }
        if n > 0 { writeBuffer.removeFirst(n) }
    }

    // ── StreamDelegate ────────────────────────────────────────────────────────

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            StoatDebug.log("socket: openCompleted, output=\(aStream === outputStream)")
            if aStream === outputStream && !handshakeDone { sendHandshake() }
        case .hasBytesAvailable:
            if aStream === inputStream  { readAvailable() }
        case .hasSpaceAvailable:
            if aStream === outputStream { flushWrite() }
        case .errorOccurred:
            let errDesc = aStream.streamError?.localizedDescription ?? "unknown"
            StoatDebug.log("socket: errorOccurred: \(errDesc)")
            disconnect()
        case .endEncountered:
            StoatDebug.log("socket: endEncountered")
            disconnect()
        default:
            break
        }
    }

    private func readAvailable() {
        guard let input = inputStream else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let n = input.read(&buf, maxLength: buf.count)
            if n > 0 { readBuffer.append(contentsOf: buf[0..<n]) }
            else if n <= 0 { break }
        }
        if !handshakeDone { processHandshake() } else { processFrames() }
    }

    // ── HTTP Upgrade handshake ────────────────────────────────────────────────

    private func sendHandshake() {
        let key = generateKey()
        let req = "GET \(_path) HTTP/1.1\r\n"
                + "Host: \(_host)\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(key)\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "\r\n"
        writeRaw(req.data(using: .utf8)!)
    }

    private func processHandshake() {
        // Search for \r\n\r\n directly in bytes — avoids String character-vs-byte mismatch
        // when frame header bytes (e.g. 0x81) follow the HTTP response in the same read.
        let cr: UInt8 = 0x0D, lf: UInt8 = 0x0A
        var consumed: Int? = nil
        let bytes = readBuffer
        if bytes.count >= 4 {
            for i in 0...(bytes.count - 4) {
                if bytes[i] == cr && bytes[i+1] == lf && bytes[i+2] == cr && bytes[i+3] == lf {
                    consumed = i + 4
                    break
                }
            }
        }
        guard let headerEnd = consumed else { return }

        // Check for 101 in the header section only
        let headerData = Data(readBuffer.prefix(headerEnd))
        guard let headerStr = String(data: headerData, encoding: .utf8),
              headerStr.contains("101") else { disconnect(); return }

        StoatDebug.log("socket: headerEnd=\(headerEnd) bufAfter=\(readBuffer.count - headerEnd)")
        readBuffer = Data(readBuffer.dropFirst(headerEnd))

        StoatDebug.log("socket: handshake OK, sending Authenticate")
        handshakeDone = true
        if let t = token { sendJSON(["type": "Authenticate", "token": t]) }
        StoatDebug.log("socket: Authenticate sent, creating timer")

        // Ping every 30s — matches React StoatSocket
        let t = Timer(timeInterval: 30, target: self,
                      selector: #selector(sendPing), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pingTimer = t
        StoatDebug.log("socket: timer created, readBuffer.count=\(readBuffer.count)")

        // Process any frame bytes that arrived in the same segment as the 101 response
        if !readBuffer.isEmpty { processFrames() }
    }

    @objc private func sendPing() { sendJSON(["type": "Ping"]) }

    // ── Frame parsing ─────────────────────────────────────────────────────────

    private func processFrames() {
        // Normalize startIndex to 0 — Data.removeFirst can leave a non-zero startIndex
        if readBuffer.startIndex != readBuffer.indices.lowerBound || readBuffer.startIndex != 0 {
            readBuffer = Data(readBuffer)
        }
        while true {
            guard readBuffer.count >= 2 else { return }

            let b0 = readBuffer[0], b1 = readBuffer[1]
            let fin    = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
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
                // 8-byte length: accumulate via UInt64 to avoid Int32 overflow on armv7
                guard readBuffer.count >= 10 else { return }
                var len64: UInt64 = 0
                for i in 2..<10 { len64 = (len64 << 8) | UInt64(readBuffer[i]) }
                guard len64 <= UInt64(Int.max) else { disconnect(); return }
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

            guard payLen >= 0 else { disconnect(); return }
            let total = hdrEnd + payLen
            guard total >= hdrEnd else { disconnect(); return }  // overflow check
            guard readBuffer.count >= total else { return }

            var payload = readBuffer.subdata(in: hdrEnd..<total)
            if let mask = maskKey {
                for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
            }
            readBuffer = Data(readBuffer.dropFirst(total))

            switch opcode {
            case 0x0:  // continuation
                fragBuffer.append(payload)
                if fin { deliver(fragBuffer); fragBuffer = Data() }
            case 0x1:  // text
                if fin { deliver(payload) } else { fragBuffer = payload }
            case 0x8:  // close
                let code = payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : -1
                let reason = payload.count > 2 ? (String(data: Data(payload[2...]), encoding: .utf8) ?? "(binary)") : ""
                StoatDebug.log("socket: close frame code=\(code) reason=\(reason)")
                disconnect()
            case 0x9:  // ping → pong
                StoatDebug.log("socket: ping received, sending pong")
                sendFrame(opcode: 0xA, payload: payload)
            default:
                break
            }
        }
    }

    private func deliver(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(40), encoding: .utf8) ?? "(binary)"
            StoatDebug.log("socket: deliver JSON fail, preview: \(preview)")
            return
        }
        let type = json["type"] as? String ?? ""
        StoatDebug.log("socket: deliver type=\(type)")

        if type == "Ready" {
            servers = (json["servers"] as? [[String: Any]] ?? [])
                .compactMap { StoatServer.from(dict: $0) }
            let chList = (json["channels"] as? [[String: Any]] ?? [])
                .compactMap { StoatChannel.from(dict: $0) }
            StoatDebug.log("socket: parsed \(servers.count) servers, \(chList.count) channels")
            allChannels = chList.reduce(into: [:]) { $0[$1.id] = $1 }
            // json["user"] (singular) = logged-in user in some API versions
            if let meDict = json["user"] as? [String: Any],
               let me = StoatUser.from(dict: meDict) {
                currentUser = me
                allUsers[me.id] = me
                StoatDebug.log("socket: currentUser from Ready.user=\(me.username)")
            }
            // json["users"] (plural) = related users
            let userList = (json["users"] as? [[String: Any]] ?? []).compactMap { StoatUser.from(dict: $0) }
            for u in userList { allUsers[u.id] = u }

            // Always fetch /users/@me — reliable across all API versions
            if let tok = token {
                HTTPClient.request("\(APIClient.baseURL)/users/@me", method: "GET",
                                   headers: ["x-session-token": tok]) { [weak self] data, _, _ in
                    guard let self = self,
                          let data = data,
                          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let me   = StoatUser.from(dict: dict) else { return }
                    self.currentUser = me
                    self.allUsers[me.id] = me
                    StoatDebug.log("socket: currentUser=\(me.username) id=\(me.id)")
                }
            }

            reconnectDelay = 3  // reset backoff on successful connection
            onReady?()
            updateBadge()
            fetchUnreads()   // seed unread dots from server-persisted read state
            StoatDebug.log("socket: onReady returned")
        } else if type == "Message" {
            if let chId = json["channel"] as? String {
                if allChannels[chId] == nil { fetchAndCacheChannel(chId) }
                if chId != activeChannelId {
                    unreadChannelIds.insert(chId)
                    updateBadge()
                    onNewMessage?(chId)
                }
            }
        }
        onEvent?(json)
    }

    // ── Base64 (no Data.base64EncodedString — iOS 7+) ────────────────────────

    private static let b64 = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    private func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = UInt8(arc4random_uniform(256)) }
        var out = ""
        var i = 0
        while i < bytes.count {
            let b0 = bytes[i]
            let b1 = i+1 < bytes.count ? bytes[i+1] : 0
            let b2 = i+2 < bytes.count ? bytes[i+2] : 0
            out.append(StoatSocket.b64[Int(b0 >> 2)])
            out.append(StoatSocket.b64[Int((b0 & 3) << 4 | b1 >> 4)])
            out.append(i+1 < bytes.count ? StoatSocket.b64[Int((b1 & 15) << 2 | b2 >> 6)] : "=")
            out.append(i+2 < bytes.count ? StoatSocket.b64[Int(b2 & 63)] : "=")
            i += 3
        }
        return out
    }
}
