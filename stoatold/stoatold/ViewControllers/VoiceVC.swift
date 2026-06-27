import UIKit

// Phase 2 voice UI — signaling + WebRTC audio.
// Shows connection status and participants in the call.
class VoiceVC: UIViewController {

    private let channel: StoatChannel

    private let statusLbl   = UILabel()
    private let participantsTbl = UITableView(frame: .zero, style: .plain)
    private let leaveBtn    = UIButton(type: .custom)

    private var participants: [String] = []   // user IDs currently in the call

    init(channel: StoatChannel) {
        self.channel = channel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = channel.name
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "< Back", style: .plain, target: self, action: #selector(leave))

        buildUI()
        setupSignaling()
        VortexSignaling.shared.joinVoice(channelId: channel.id)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { VortexSignaling.shared.leave() }
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
        participantsTbl.frame           = CGRect(x: 0, y: 40, width: w, height: h - 80)
        participantsTbl.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        participantsTbl.separatorColor  = UIColor(white: 1, alpha: 0.07)
        participantsTbl.rowHeight       = 52
        participantsTbl.dataSource      = self
        participantsTbl.register(ParticipantCell.self, forCellReuseIdentifier: "p")
        view.addSubview(participantsTbl)

        // Leave button at bottom
        leaveBtn.backgroundColor = UIColor(red: 0.70, green: 0.18, blue: 0.18, alpha: 1)
        leaveBtn.setTitle("Leave Call", for: .normal)
        leaveBtn.setTitleColor(.white, for: .normal)
        leaveBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        leaveBtn.layer.cornerRadius = 8
        leaveBtn.layer.masksToBounds = true
        leaveBtn.frame = CGRect(x: 20, y: h - 36, width: w - 40, height: 44)
        leaveBtn.addTarget(self, action: #selector(leave), for: .touchUpInside)
        view.addSubview(leaveBtn)
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
        }
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
            cell.configure(name: "No one else in the call", isSpeaking: false, isEmpty: true)
        } else {
            let uid  = participants[indexPath.row]
            let name = StoatSocket.shared.allUsers[uid]?.username ?? uid
            cell.configure(name: name, isSpeaking: false, isEmpty: false)
        }
        return cell
    }
}

// MARK: - ParticipantCell

private class ParticipantCell: UITableViewCell {

    private let avatarView = UIView()
    private let nameLbl    = UILabel()
    private let speakDot   = UIView()

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

    func configure(name: String, isSpeaking: Bool, isEmpty: Bool) {
        nameLbl.text      = name
        nameLbl.textColor = isEmpty
            ? UIColor(white: 0.35, alpha: 1)
            : UIColor(white: 0.85, alpha: 1)
        nameLbl.font = isEmpty
            ? UIFont.italicSystemFont(ofSize: 14)
            : UIFont.systemFont(ofSize: 15)
        avatarView.isHidden = isEmpty
        speakDot.isHidden   = !isSpeaking
    }
}
