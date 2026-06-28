import UIKit

// Phase 2 voice UI — signaling + WebRTC audio.
// Shows connection status and participants in the call.
class VoiceVC: UIViewController {

    private let channel: StoatChannel

    private let statusLbl   = UILabel()
    private let participantsTbl = UITableView(frame: .zero, style: .plain)
    private let leaveBtn    = UIButton(type: .custom)
    private let micBtn      = UIButton(type: .custom)
    private let deafBtn     = UIButton(type: .custom)

    private var participants: [String] = []   // user IDs currently in the call
    private var memberNames:   [String: String] = [:]   // uid -> nickname ?? username
    private var memberAvatars: [String: String] = [:]   // uid -> avatar URL

    init(channel: StoatChannel) {
        self.channel = channel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = channel.name
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)

        buildUI()
        setupSignaling()
        fetchServerMembers()
        VortexSignaling.shared.joinVoice(channelId: channel.id)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            VortexWebRTC.shared.stop()
            VortexSignaling.shared.leave()
        }
    }

    // MARK: - UI

    private func buildUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height - 88

        // Status bar at top
        statusLbl.backgroundColor = UIColor(red: 0.14, green: 0.14, blue: 0.18, alpha: 1)
        statusLbl.textColor       = UIColor(white: 0.55, alpha: 1)
        statusLbl.font            = UIFont.systemFont(ofSize: 13)
        statusLbl.textAlignment   = .center
        statusLbl.text            = "Connecting..."
        statusLbl.frame           = CGRect(x: 0, y: 0, width: w, height: 40)
        view.addSubview(statusLbl)

        // Participants table
        participantsTbl.frame           = CGRect(x: 0, y: 40, width: w, height: h - 116)
        participantsTbl.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        participantsTbl.separatorColor  = UIColor(white: 1, alpha: 0.07)
        participantsTbl.rowHeight       = 52
        participantsTbl.dataSource      = self
        participantsTbl.register(ParticipantCell.self, forCellReuseIdentifier: "p")
        view.addSubview(participantsTbl)

        // Bottom control row: three round icon buttons — Mic | Deafen | Leave.
        let d: CGFloat   = 58
        let gap: CGFloat = 26
        let rowY  = h - 64
        let total = d * 3 + gap * 2
        var x     = (w - total) / 2

        let darkBG = UIColor(red: 0.20, green: 0.20, blue: 0.26, alpha: 1)

        styleRoundButton(micBtn, bg: darkBG, diameter: d)
        micBtn.frame = CGRect(x: x, y: rowY, width: d, height: d)
        micBtn.addTarget(self, action: #selector(toggleMic), for: .touchUpInside)
        view.addSubview(micBtn)
        x += d + gap

        styleRoundButton(deafBtn, bg: darkBG, diameter: d)
        deafBtn.frame = CGRect(x: x, y: rowY, width: d, height: d)
        deafBtn.addTarget(self, action: #selector(toggleDeafen), for: .touchUpInside)
        view.addSubview(deafBtn)
        x += d + gap

        styleRoundButton(leaveBtn, bg: UIColor(red: 0.70, green: 0.18, blue: 0.18, alpha: 1), diameter: d)
        leaveBtn.frame = CGRect(x: x, y: rowY, width: d, height: d)
        leaveBtn.setImage(VoiceVC.leaveImage(), for: .normal)
        leaveBtn.addTarget(self, action: #selector(leave), for: .touchUpInside)
        view.addSubview(leaveBtn)

        updateMicIcon()
        updateDeafIcon()
    }

    private func styleRoundButton(_ b: UIButton, bg: UIColor, diameter: CGFloat) {
        b.backgroundColor      = bg
        b.layer.cornerRadius   = diameter / 2
        b.layer.masksToBounds  = true
    }

    private func updateMicIcon() {
        micBtn.setImage(VoiceVC.micImage(muted: !VortexWebRTC.shared.isMicEnabled), for: .normal)
    }

    private func updateDeafIcon() {
        deafBtn.setImage(VoiceVC.headphonesImage(off: VortexWebRTC.shared.isDeafened), for: .normal)
    }

    // MARK: - Icon drawing (CoreGraphics — iOS 6 safe, no asset catalog needed)

    private static let slashBG = UIColor(red: 0.20, green: 0.20, blue: 0.26, alpha: 1)

    /// Renders a white glyph in a 30pt box; when `slashed` overlays a red "/" with a
    /// background-coloured cut beneath it so it reads as crossed-out.
    private static func iconImage(slashed: Bool, slashCutColor: UIColor,
                                  _ draw: (CGFloat) -> Void) -> UIImage {
        let s: CGFloat = 30
        UIGraphicsBeginImageContextWithOptions(CGSize(width: s, height: s), false, 0)
        draw(s)
        if slashed {
            let cut = UIBezierPath()
            cut.move(to: CGPoint(x: s * 0.16, y: s * 0.20))
            cut.addLine(to: CGPoint(x: s * 0.84, y: s * 0.86))
            cut.lineWidth   = max(4, s * 0.18)
            cut.lineCapStyle = .round
            slashCutColor.setStroke(); cut.stroke()

            let slash = UIBezierPath()
            slash.move(to: CGPoint(x: s * 0.18, y: s * 0.18))
            slash.addLine(to: CGPoint(x: s * 0.86, y: s * 0.84))
            slash.lineWidth   = max(2, s * 0.09)
            slash.lineCapStyle = .round
            UIColor(red: 0.95, green: 0.42, blue: 0.42, alpha: 1).setStroke(); slash.stroke()
        }
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img ?? UIImage()
    }

    private static func micImage(muted: Bool) -> UIImage {
        return iconImage(slashed: muted, slashCutColor: slashBG) { s in
            UIColor.white.setFill(); UIColor.white.setStroke()
            let lw = max(1.5, s * 0.07)
            let bw = s * 0.30, bh = s * 0.42
            let bx = (s - bw) / 2, by = s * 0.12
            UIBezierPath(roundedRect: CGRect(x: bx, y: by, width: bw, height: bh),
                         cornerRadius: bw / 2).fill()
            let arc = UIBezierPath(arcCenter: CGPoint(x: s / 2, y: by + bh * 0.55),
                                   radius: bw * 0.95, startAngle: 0, endAngle: CGFloat.pi,
                                   clockwise: true)
            arc.lineWidth = lw; arc.stroke()
            let stand = UIBezierPath()
            stand.move(to: CGPoint(x: s / 2, y: by + bh * 0.55 + bw * 0.95))
            stand.addLine(to: CGPoint(x: s / 2, y: s * 0.86))
            stand.lineWidth = lw; stand.stroke()
            let base = UIBezierPath()
            base.move(to: CGPoint(x: s * 0.34, y: s * 0.86))
            base.addLine(to: CGPoint(x: s * 0.66, y: s * 0.86))
            base.lineWidth = lw; base.stroke()
        }
    }

    private static func headphonesImage(off: Bool) -> UIImage {
        return iconImage(slashed: off, slashCutColor: slashBG) { s in
            UIColor.white.setFill(); UIColor.white.setStroke()
            let lw = max(1.5, s * 0.07)
            let r  = s * 0.30
            let band = UIBezierPath(arcCenter: CGPoint(x: s / 2, y: s * 0.54),
                                    radius: r, startAngle: CGFloat.pi, endAngle: 2 * CGFloat.pi,
                                    clockwise: true)
            band.lineWidth = lw; band.stroke()
            let cw = s * 0.15, ch = s * 0.26
            UIBezierPath(roundedRect: CGRect(x: s / 2 - r - cw / 2, y: s * 0.50, width: cw, height: ch),
                         cornerRadius: cw * 0.4).fill()
            UIBezierPath(roundedRect: CGRect(x: s / 2 + r - cw / 2, y: s * 0.50, width: cw, height: ch),
                         cornerRadius: cw * 0.4).fill()
        }
    }

    private static func leaveImage() -> UIImage {
        return iconImage(slashed: false, slashCutColor: .clear) { s in
            UIColor.white.setStroke()
            let p = UIBezierPath()
            p.move(to: CGPoint(x: s * 0.32, y: s * 0.32)); p.addLine(to: CGPoint(x: s * 0.68, y: s * 0.68))
            p.move(to: CGPoint(x: s * 0.68, y: s * 0.32)); p.addLine(to: CGPoint(x: s * 0.32, y: s * 0.68))
            p.lineWidth = max(2, s * 0.10); p.lineCapStyle = .round; p.stroke()
        }
    }

    // MARK: - Member info (nickname + avatar, same source as the member list)

    private func fetchServerMembers() {
        guard let serverId = channel.serverId else { return }
        APIClient.get("/servers/\(serverId)/members") { [weak self] json, err in
            guard let self = self, err == nil, let dict = json as? [String: Any] else { return }
            let users = dict["users"] as? [[String: Any]] ?? []
            var userMap: [String: [String: Any]] = [:]
            for u in users { if let id = u["_id"] as? String { userMap[id] = u } }

            let memberList = dict["members"] as? [[String: Any]] ?? []
            for mem in memberList {
                let uid: String
                if let mid = mem["_id"] as? String {
                    uid = mid
                } else if let mid = mem["_id"] as? [String: Any],
                          let u = mid["user"] as? String {
                    uid = u
                } else { continue }

                let userDict = userMap[uid] ?? [:]
                let username = userDict["username"] as? String ?? uid
                let nickname = mem["nickname"] as? String
                self.memberNames[uid] = nickname ?? username
                // server member avatar takes priority over the global user avatar
                if let aid = ((mem["avatar"] as? [String: Any])?["_id"] as? String)
                    ?? ((userDict["avatar"] as? [String: Any])?["_id"] as? String) {
                    self.memberAvatars[uid] = "https://cdn.stoatusercontent.com/avatars/\(aid)"
                }
            }
            self.participantsTbl.reloadData()
        }
    }

    // MARK: - Signaling callbacks

    private func setupSignaling() {
        let sig = VortexSignaling.shared

        sig.onTransportReady = { [weak self] info in
            DispatchQueue.main.async {
                self?.statusLbl.text      = "Connected  ·  \(info.ip):\(info.port)"
                self?.statusLbl.textColor = UIColor(red: 0.35, green: 0.75, blue: 0.45, alpha: 1)
            }
            // Ask server for current participants
            sig.requestRoomInfo()
        }

        sig.onParticipants = { [weak self] ids in
            DispatchQueue.main.async {
                self?.participants = ids
                self?.participantsTbl.reloadData()
            }
        }

        sig.onUserJoined = { [weak self] userId in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !self.participants.contains(userId) {
                    self.participants.append(userId)
                    self.participantsTbl.reloadData()
                }
            }
        }

        sig.onUserLeft = { [weak self] userId in
            DispatchQueue.main.async {
                self?.participants.removeAll { $0 == userId }
                self?.participantsTbl.reloadData()
            }
        }

        sig.onUserStartAudio = { [weak self] userId in
            DispatchQueue.main.async { self?.participantsTbl.reloadData() }
        }

        sig.onUserStopAudio = { [weak self] _ in
            DispatchQueue.main.async { self?.participantsTbl.reloadData() }
        }

        sig.onConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.statusLbl.text      = "Connected to voice channel"
                self?.statusLbl.textColor = UIColor(red: 0.35, green: 0.75, blue: 0.45, alpha: 1)
            }
        }

        sig.onError = { [weak self] msg in
            DispatchQueue.main.async {
                self?.statusLbl.text      = "Error: \(msg)"
                self?.statusLbl.textColor = UIColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1)
            }
        }

        sig.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.statusLbl.text      = "Disconnected"
                self?.statusLbl.textColor = UIColor(white: 0.45, alpha: 1)
            }
        }

        sig.onIceServersRaw = { [weak self] entries in
            guard let self = self else { return }
            VortexWebRTC.shared.configure(withIceServersRaw: entries)
            VortexWebRTC.shared.onAudioConnected = { [weak self] in
                DispatchQueue.main.async {
                    self?.statusLbl.text      = "Audio connected"
                    self?.statusLbl.textColor = UIColor(red: 0.35, green: 0.75, blue: 0.45, alpha: 1)
                }
            }
            VortexWebRTC.shared.onError = { [weak self] msg in
                DispatchQueue.main.async {
                    self?.statusLbl.text      = "Audio error: \(msg)"
                    self?.statusLbl.textColor = UIColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1)
                }
            }
            VortexWebRTC.shared.start()
            VortexWebRTC.shared.setMicEnabled(true)
            DispatchQueue.main.async { self.updateMicIcon() }
        }
    }

    @objc private func toggleMic() {
        VortexWebRTC.shared.setMicEnabled(!VortexWebRTC.shared.isMicEnabled)
        updateMicIcon()
    }

    @objc private func toggleDeafen() {
        VortexWebRTC.shared.setDeafened(!VortexWebRTC.shared.isDeafened)
        updateDeafIcon()
    }

    @objc private func leave() {
        VortexWebRTC.shared.stop()
        VortexSignaling.shared.leave()
        navigationController?.popViewController(animated: true)
    }
}

// MARK: - UITableViewDataSource

extension VoiceVC: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return participants.isEmpty ? 1 : participants.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "p", for: indexPath) as! ParticipantCell
        if participants.isEmpty {
            cell.configure(uid: "", name: "No one else in the call",
                           avatarURL: nil, isSpeaking: false, isEmpty: true)
        } else {
            let uid  = participants[indexPath.row]
            let name = memberNames[uid] ?? StoatSocket.shared.allUsers[uid]?.username ?? uid
            cell.configure(uid: uid, name: name, avatarURL: memberAvatars[uid],
                           isSpeaking: false, isEmpty: false)
        }
        return cell
    }
}

// MARK: - ParticipantCell

private class ParticipantCell: UITableViewCell {

    private let avatarView  = UIView()
    private let avatarLabel = UILabel()
    private let avatarImage = UIImageView()
    private let nameLbl     = UILabel()
    private let speakDot    = UIView()
    private var currentAvatarURL: String?

    private static let accents: [UIColor] = [
        UIColor(red: 0.55, green: 0.27, blue: 0.87, alpha: 1),
        UIColor(red: 0.23, green: 0.65, blue: 0.35, alpha: 1),
        UIColor(red: 0.20, green: 0.55, blue: 0.87, alpha: 1),
        UIColor(red: 0.87, green: 0.35, blue: 0.20, alpha: 1),
    ]

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor    = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        selectionStyle     = .none

        // Avatar circle
        avatarView.backgroundColor    = UIColor(red: 0.2, green: 0.2, blue: 0.26, alpha: 1)
        avatarView.layer.cornerRadius = 18
        avatarView.layer.masksToBounds = true
        avatarView.frame = CGRect(x: 16, y: 8, width: 36, height: 36)
        contentView.addSubview(avatarView)

        avatarLabel.backgroundColor = .clear
        avatarLabel.textColor       = .white
        avatarLabel.font            = UIFont.boldSystemFont(ofSize: 16)
        avatarLabel.textAlignment   = .center
        avatarLabel.frame           = avatarView.bounds
        avatarView.addSubview(avatarLabel)

        avatarImage.contentMode   = .scaleAspectFill
        avatarImage.clipsToBounds = true
        avatarImage.frame         = avatarView.bounds
        avatarImage.isHidden      = true
        avatarView.addSubview(avatarImage)

        // Name label
        nameLbl.backgroundColor = .clear
        nameLbl.textColor       = UIColor(white: 0.85, alpha: 1)
        nameLbl.font            = UIFont.systemFont(ofSize: 15)
        nameLbl.frame           = CGRect(x: 64, y: 0,
                                         width: UIScreen.main.bounds.width - 88, height: 52)
        contentView.addSubview(nameLbl)

        // Speaking indicator dot (green, right side)
        speakDot.backgroundColor    = UIColor(red: 0.35, green: 0.75, blue: 0.45, alpha: 1)
        speakDot.layer.cornerRadius = 5
        speakDot.layer.masksToBounds = true
        speakDot.frame    = CGRect(x: UIScreen.main.bounds.width - 24, y: 21, width: 10, height: 10)
        speakDot.isHidden = true
        contentView.addSubview(speakDot)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(uid: String, name: String, avatarURL: String?,
                   isSpeaking: Bool, isEmpty: Bool) {
        nameLbl.text      = name
        nameLbl.textColor = isEmpty
            ? UIColor(white: 0.35, alpha: 1)
            : UIColor(white: 0.85, alpha: 1)
        nameLbl.font = isEmpty
            ? UIFont.italicSystemFont(ofSize: 14)
            : UIFont.systemFont(ofSize: 15)
        avatarView.isHidden = isEmpty
        speakDot.isHidden   = !isSpeaking

        if isEmpty {
            avatarLabel.text = ""
            loadAvatar(nil)
        } else {
            avatarLabel.text = String(name.prefix(1)).uppercased()
            let idx = (uid.unicodeScalars.first.map { Int($0.value) } ?? 0)
                % ParticipantCell.accents.count
            avatarView.backgroundColor = ParticipantCell.accents[idx]
            loadAvatar(avatarURL)
        }
    }

    private func loadAvatar(_ urlString: String?) {
        avatarImage.image    = nil
        avatarImage.isHidden = true
        currentAvatarURL     = urlString
        guard let urlString = urlString else { return }
        CDNImage.load(urlString) { [weak self] img in
            guard let img = img, let self = self,
                  self.currentAvatarURL == urlString else { return }
            self.avatarImage.image    = img
            self.avatarImage.isHidden = false
        }
    }
}
