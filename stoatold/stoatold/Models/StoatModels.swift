import Foundation

struct StoatServer {
    let id:         String
    let name:       String
    let channelIds: [String]
    let iconId:     String?

    // autumn CDN: server icons live at {CDN}/icons/{file_id} (mirrors the web client)
    var iconURL: String? {
        guard let iconId = iconId else { return nil }
        return "https://cdn.stoatusercontent.com/icons/\(iconId)"
    }

    static func from(dict: [String: Any]) -> StoatServer? {
        guard let id   = dict["_id"]  as? String,
              let name = dict["name"] as? String else { return nil }
        let channelIds = dict["channels"] as? [String] ?? []
        let iconId = (dict["icon"] as? [String: Any])?["_id"] as? String
        return StoatServer(id: id, name: name, channelIds: channelIds, iconId: iconId)
    }
}

struct StoatChannel {
    let id:         String
    let name:       String
    let type:       String   // "TextChannel" | "VoiceChannel" | "DirectMessage" | "Group"
    let serverId:   String?
    let recipients: [String]
    let lastMessageId: String?   // ULID of the last message — used for unread detection

    var isText:   Bool { return type == "TextChannel"  }
    var isVoice:  Bool { return type == "VoiceChannel" }
    var isDirect: Bool { return type == "DirectMessage" || type == "Group" }

    func dmName(currentUserId: String?) -> String {
        if type == "Group" && !name.isEmpty { return name }
        let otherId = recipients.first(where: { $0 != currentUserId }) ?? recipients.first ?? id
        return StoatSocket.shared.allUsers[otherId]?.username ?? name
    }

    static func from(dict: [String: Any]) -> StoatChannel? {
        guard let id = dict["_id"] as? String else { return nil }
        let name    = dict["name"]         as? String ?? ""
        let rawType = dict["channel_type"] as? String ?? "TextChannel"
        // Voice channels are TextChannel with a non-null voice field (mirrors React)
        let hasVoice = !(dict["voice"] == nil || dict["voice"] is NSNull)
        let type    = hasVoice ? "VoiceChannel" : rawType
        let serverId   = dict["server"]       as? String
        let recipients = dict["recipients"]   as? [String] ?? []
        let lastMessageId = dict["last_message_id"] as? String
        return StoatChannel(id: id, name: name, type: type,
                            serverId: serverId, recipients: recipients,
                            lastMessageId: lastMessageId)
    }
}

struct StoatUser {
    let id:           String
    let username:     String
    let relationship: String?  // "Friend" | "Incoming" | "Outgoing" | "Blocked" | nil

    static func from(dict: [String: Any]) -> StoatUser? {
        guard let id       = dict["_id"]      as? String,
              let username = dict["username"] as? String else { return nil }
        let relationship = dict["relationship"] as? String
        return StoatUser(id: id, username: username, relationship: relationship)
    }
}

// File/image attachment on a message
struct StoatAttachment {
    let id:          String
    let filename:    String
    let contentType: String
    let width:       Int
    let height:      Int

    var isImage: Bool   {
        if contentType.hasPrefix("image/") { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp"].contains(ext)
    }
    var url: String {
        let enc = filename.replacingOccurrences(of: " ", with: "%20")
        let name = enc.isEmpty ? "image.jpg" : enc
        return "https://cdn.stoatusercontent.com/attachments/\(id)/\(name)"
    }

    static func from(dict: [String: Any]) -> StoatAttachment? {
        guard let id = dict["_id"] as? String ?? dict["id"] as? String else {
            StoatDebug.log("attach.from: no id — keys=\(Array(dict.keys))")
            return nil
        }
        let filename    = dict["filename"]     as? String ?? ""
        let contentType = dict["content_type"] as? String ?? ""
        StoatDebug.log("attach.from: id=\(id) ct=\(contentType) file=\(filename)")
        let meta        = dict["metadata"]     as? [String: Any] ?? [:]
        let width       = meta["width"]        as? Int ?? 0
        let height      = meta["height"]       as? Int ?? 0
        return StoatAttachment(id: id, filename: filename, contentType: contentType,
                               width: width, height: height)
    }
}

struct StoatMessage {
    let id:          String
    let channelId:   String
    let authorId:    String
    var content:     String
    let displayName: String?
    let timestamp:   Date?
    let attachments: [StoatAttachment]
    var edited:      Bool = false
    let replies:     [String]

    var authorName: String {
        if let n = displayName { return n }
        if let u = StoatSocket.shared.allUsers[authorId] { return u.username }
        return authorId
    }

    static func from(dict: [String: Any]) -> StoatMessage? {
        guard let id      = dict["_id"]     as? String,
              let channel = dict["channel"] as? String else { return nil }
        let content = dict["content"] as? String ?? ""

        let authorId:    String
        var displayName: String? = nil

        if let a = dict["author"] as? String {
            authorId = a
            // member nickname > user username
            if let member = dict["member"] as? [String: Any],
               let nick   = member["nickname"] as? String, !nick.isEmpty {
                displayName = nick
            } else if let u = dict["user"] as? [String: Any] {
                displayName = u["username"] as? String
            }
        } else if let a = dict["author"] as? [String: Any],
                  let aid = a["_id"] as? String {
            authorId    = aid
            displayName = (a["username"] as? String) ?? (a["display_name"] as? String)
        } else {
            authorId = "unknown"
        }

        // Parse timestamp: explicit field first, then extract from ULID _id
        var timestamp: Date? = nil
        if let ts = dict["createdAt"] as? String ?? dict["timestamp"] as? String {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            for f in ["yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
                       "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                       "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
                       "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
                       "yyyy-MM-dd'T'HH:mm:ssZ"] {
                fmt.dateFormat = f
                if let d = fmt.date(from: ts) { timestamp = d; break }
            }
        }
        if timestamp == nil { timestamp = ulidTimestamp(id) }

        // Attachments may arrive as full objects or bare ID strings
        var attachments: [StoatAttachment] = []
        if let arr = dict["attachments"] as? [[String: Any]] {
            attachments = arr.compactMap { StoatAttachment.from(dict: $0) }
            StoatDebug.log("msg: attachments objects count=\(arr.count) parsed=\(attachments.count)")
        } else if let ids = dict["attachments"] as? [String] {
            // WebSocket may send bare IDs — synthesise minimal attachment
            // We default to image type; the actual MIME is confirmed on download
            attachments = ids.map {
                StoatAttachment(id: $0, filename: "", contentType: "image/jpeg",
                                width: 0, height: 0)
            }
            StoatDebug.log("msg: attachments bare IDs count=\(ids.count)")
        } else if let raw = dict["attachments"] {
            StoatDebug.log("msg: attachments unexpected type: \(type(of: raw))")
        }

        let edited = dict["edited"] != nil
        let replies = dict["replies"] as? [String] ?? []
        return StoatMessage(id: id, channelId: channel, authorId: authorId,
                            content: content, displayName: displayName,
                            timestamp: timestamp, attachments: attachments,
                            edited: edited, replies: replies)
    }

    // Crockford base32 decode of ULID timestamp (first 10 chars = 48-bit ms)
    private static func ulidTimestamp(_ ulid: String) -> Date? {
        let alpha = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var ms: UInt64 = 0
        for ch in ulid.prefix(10).uppercased() {
            guard let idx = alpha.firstIndex(of: ch) else { return nil }
            ms = ms &* 32 &+ UInt64(idx)
        }
        guard ms > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }
}
