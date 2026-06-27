import UIKit

class DMListVC: UIViewController {

    private var pendingRequests: [StoatUser] = []
    private var dms:             [StoatChannel] = []
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var activeAlert: UIAlertView?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Direct Messages"
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "+", style: .plain, target: self, action: #selector(newDMTapped))
        dms = StoatSocket.shared.dmChannels
        buildUI()
        fetchFriendRequests()
        resolveParticipantNames()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        dms = StoatSocket.shared.dmChannels
        pendingRequests = StoatSocket.shared.pendingFriendRequests
        tableView.reloadData()
        StoatSocket.shared.onNewMessage = { [weak self] _ in
            self?.dms = StoatSocket.shared.dmChannels
            self?.tableView.reloadData()
        }
        StoatSocket.shared.onNewChannel = { [weak self] in
            self?.dms = StoatSocket.shared.dmChannels
            self?.tableView.reloadData()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        StoatSocket.shared.onNewMessage = nil
        StoatSocket.shared.onNewChannel = nil
    }

    private func buildUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height - 64

        tableView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        tableView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        tableView.separatorColor  = UIColor(white: 1, alpha: 0.07)
        tableView.separatorStyle  = .singleLine
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.register(DMCell.self,            forCellReuseIdentifier: "dm")
        tableView.register(FriendRequestCell.self, forCellReuseIdentifier: "fr")
        view.addSubview(tableView)
    }

    // MARK: - Data

    private func fetchFriendRequests() {
        pendingRequests = StoatSocket.shared.pendingFriendRequests
        tableView.reloadData()
    }

    // Fetch usernames for DM participants not yet in the user cache
    private func resolveParticipantNames() {
        let myId = StoatSocket.shared.currentUser?.id
        var pending = 0
        for ch in dms {
            for uid in ch.recipients where uid != myId && StoatSocket.shared.allUsers[uid] == nil {
                pending += 1
                APIClient.get("/users/\(uid)") { [weak self] json, _ in
                    if let dict = json as? [String: Any], let u = StoatUser.from(dict: dict) {
                        StoatSocket.shared.cacheUser(u)
                    }
                    pending -= 1
                    if pending == 0 { self?.tableView.reloadData() }
                }
            }
        }
    }

    private func acceptRequest(_ user: StoatUser) {
        guard let token = APIClient.sessionToken else { return }
        HTTPClient.request("\(APIClient.baseURL)/users/\(user.id)/friend",
                           method: "PUT",
                           headers: ["x-session-token": token]) { [weak self] _, status, err in
            StoatDebug.log("friend accept status=\(status) err=\(err?.localizedDescription ?? "nil")")
            let updated = StoatUser(id: user.id, username: user.username, relationship: "Friend")
            StoatSocket.shared.cacheUser(updated)
            self?.fetchFriendRequests()
        }
    }

    private func declineRequest(_ user: StoatUser) {
        guard let token = APIClient.sessionToken else { return }
        HTTPClient.request("\(APIClient.baseURL)/users/\(user.id)/friend",
                           method: "DELETE",
                           headers: ["x-session-token": token]) { [weak self] _, status, err in
            StoatDebug.log("friend decline status=\(status) err=\(err?.localizedDescription ?? "nil")")
            let updated = StoatUser(id: user.id, username: user.username, relationship: nil)
            StoatSocket.shared.cacheUser(updated)
            self?.fetchFriendRequests()
        }
    }

    @objc private func newDMTapped() {
        let alert = UIAlertView(title: "New Direct Message",
                                message: "Enter username:",
                                delegate: self,
                                cancelButtonTitle: "Cancel")
        alert.alertViewStyle = UIAlertViewStyle.plainTextInput
        alert.addButton(withTitle: "Open")
        alert.tag = 99
        activeAlert = alert
        alert.show()
    }

    private func findAndOpenDM(username: String) {
        let lower = username.lowercased()
        if let user = StoatSocket.shared.allUsers.values.first(where: {
            $0.username.lowercased() == lower }) {
            openDM(userId: user.id); return
        }
        APIClient.get("/users/\(username)") { [weak self] json, _ in
            if let dict = json as? [String: Any], let u = StoatUser.from(dict: dict) {
                StoatSocket.shared.cacheUser(u)
                self?.openDM(userId: u.id)
            } else {
                let errAlert = UIAlertView(title: "Not Found",
                                          message: "User not found.",
                                          delegate: nil,
                                          cancelButtonTitle: "OK")
                errAlert.show()
            }
        }
    }

    private func openDM(userId: String) {
        APIClient.get("/users/\(userId)/dm") { [weak self] json, _ in
            guard let self = self,
                  let dict = json as? [String: Any],
                  let ch   = StoatChannel.from(dict: dict) else {
                StoatDebug.log("openDM: no channel returned")
                return
            }
            StoatSocket.shared.cacheChannel(ch)
            self.dms = StoatSocket.shared.dmChannels
            self.tableView.reloadData()
            self.navigationController?.pushViewController(ChatVC(channel: ch), animated: true)
        }
    }
}

extension DMListVC: UIAlertViewDelegate {
    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        activeAlert = nil
        guard alertView.tag == 99, buttonIndex != alertView.cancelButtonIndex else { return }
        let raw     = alertView.textField(at: 0)?.text ?? ""
        let trimmed = (raw as NSString).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        findAndOpenDM(username: trimmed)
    }
}

// MARK: - UITableViewDataSource / Delegate

extension DMListVC: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        var n = 0
        if !pendingRequests.isEmpty { n += 1 }
        if !dms.isEmpty              { n += 1 }
        return max(n, 1)  // at least 1 section so empty state shows
    }

    private func sectionKind(_ section: Int) -> String {
        if !pendingRequests.isEmpty && section == 0 { return "requests" }
        return "dms"
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sectionKind(section) {
        case "requests": return pendingRequests.count
        default:         return dms.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sectionKind(indexPath.section) {
        case "requests":
            let cell = tableView.dequeueReusableCell(withIdentifier: "fr", for: indexPath) as! FriendRequestCell
            let user = pendingRequests[indexPath.row]
            cell.configure(with: user,
                onAccept:  { [weak self] in self?.acceptRequest(user) },
                onDecline: { [weak self] in self?.declineRequest(user) })
            return cell
        default:
            let cell = tableView.dequeueReusableCell(withIdentifier: "dm", for: indexPath) as! DMCell
            cell.configure(with: dms[indexPath.row])
            return cell
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return sectionKind(indexPath.section) == "requests" ? 68 : 56
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let w = UIScreen.main.bounds.width
        let v = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 28))
        v.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        let lbl = UILabel(frame: CGRect(x: 14, y: 7, width: w - 28, height: 14))
        lbl.backgroundColor = .clear
        lbl.textColor = UIColor(white: 0.45, alpha: 1)
        lbl.font = UIFont.boldSystemFont(ofSize: 11)
        lbl.text = sectionKind(section) == "requests" ? "PENDING REQUESTS" : "DIRECT MESSAGES"
        v.addSubview(lbl)
        return v
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 28
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sectionKind(indexPath.section) == "dms" else { return }
        let ch = dms[indexPath.row]
        StoatSocket.shared.markRead(ch.id)
        navigationController?.pushViewController(ChatVC(channel: ch), animated: true)
    }
}

// MARK: - FriendRequestCell

private class FriendRequestCell: UITableViewCell {

    private let avatarView   = UIView()
    private let avatarLabel  = UILabel()
    private let nameLabel    = UILabel()
    private let acceptBtn    = UIButton(type: .custom)
    private let declineBtn   = UIButton(type: .custom)
    private var onAccept:  (() -> Void)?
    private var onDecline: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        selectionStyle  = .none

        avatarView.layer.cornerRadius = 18
        avatarView.layer.masksToBounds = true
        avatarView.backgroundColor = UIColor(red: 0.55, green: 0.27, blue: 0.87, alpha: 1)
        avatarView.frame = CGRect(x: 12, y: 10, width: 36, height: 36)
        contentView.addSubview(avatarView)

        avatarLabel.backgroundColor = .clear
        avatarLabel.textColor = .white
        avatarLabel.font = UIFont.boldSystemFont(ofSize: 15)
        avatarLabel.textAlignment = .center
        avatarLabel.frame = avatarView.bounds
        avatarView.addSubview(avatarLabel)

        nameLabel.backgroundColor = .clear
        nameLabel.textColor = .white
        nameLabel.font = UIFont.systemFont(ofSize: 15)
        nameLabel.frame = CGRect(x: 58, y: 10, width: UIScreen.main.bounds.width - 190, height: 20)
        contentView.addSubview(nameLabel)

        let w = UIScreen.main.bounds.width
        acceptBtn.backgroundColor = UIColor(red: 0.23, green: 0.65, blue: 0.35, alpha: 1)
        acceptBtn.setTitle("✓", for: .normal)
        acceptBtn.setTitleColor(.white, for: .normal)
        acceptBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        acceptBtn.layer.cornerRadius = 14
        acceptBtn.layer.masksToBounds = true
        acceptBtn.frame = CGRect(x: w - 88, y: 17, width: 34, height: 28)
        acceptBtn.addTarget(self, action: #selector(tappedAccept), for: .touchUpInside)
        contentView.addSubview(acceptBtn)

        declineBtn.backgroundColor = UIColor(red: 0.75, green: 0.25, blue: 0.25, alpha: 1)
        declineBtn.setTitle("✕", for: .normal)
        declineBtn.setTitleColor(.white, for: .normal)
        declineBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        declineBtn.layer.cornerRadius = 14
        declineBtn.layer.masksToBounds = true
        declineBtn.frame = CGRect(x: w - 48, y: 17, width: 34, height: 28)
        declineBtn.addTarget(self, action: #selector(tappedDecline), for: .touchUpInside)
        contentView.addSubview(declineBtn)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with user: StoatUser, onAccept: @escaping () -> Void, onDecline: @escaping () -> Void) {
        avatarLabel.text = String(user.username.prefix(1)).uppercased()
        nameLabel.text   = user.username
        self.onAccept  = onAccept
        self.onDecline = onDecline
    }

    @objc private func tappedAccept()  { onAccept?() }
    @objc private func tappedDecline() { onDecline?() }
}

// MARK: - DMCell

private class DMCell: UITableViewCell {

    private let avatarView  = UIView()
    private let avatarLabel = UILabel()
    private let nameLabel   = UILabel()
    private let unreadDot   = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        selectionStyle  = .default

        let sel = UIView()
        sel.backgroundColor = UIColor(white: 1, alpha: 0.06)
        selectedBackgroundView = sel

        avatarView.layer.cornerRadius = 20
        avatarView.layer.masksToBounds = true
        avatarView.frame = CGRect(x: 12, y: 8, width: 40, height: 40)
        contentView.addSubview(avatarView)

        avatarLabel.backgroundColor = .clear
        avatarLabel.textColor = .white
        avatarLabel.font = UIFont.boldSystemFont(ofSize: 17)
        avatarLabel.textAlignment = .center
        avatarLabel.frame = avatarView.bounds
        avatarView.addSubview(avatarLabel)

        nameLabel.backgroundColor = .clear
        nameLabel.textColor = .white
        nameLabel.font = UIFont.systemFont(ofSize: 16)
        nameLabel.frame = CGRect(x: 64, y: 0,
                                 width: UIScreen.main.bounds.width - 92, height: 56)
        contentView.addSubview(nameLabel)

        unreadDot.backgroundColor = UIColor(red: 0.36, green: 0.56, blue: 0.90, alpha: 1)
        unreadDot.layer.cornerRadius = 4
        unreadDot.layer.masksToBounds = true
        unreadDot.frame = CGRect(x: UIScreen.main.bounds.width - 20, y: 24, width: 8, height: 8)
        unreadDot.isHidden = true
        contentView.addSubview(unreadDot)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with ch: StoatChannel) {
        let name = ch.dmName(currentUserId: StoatSocket.shared.currentUser?.id)
        nameLabel.text   = name
        avatarLabel.text = String(name.prefix(1)).uppercased()
        let colors: [UIColor] = [
            UIColor(red: 0.55, green: 0.27, blue: 0.87, alpha: 1),
            UIColor(red: 0.23, green: 0.65, blue: 0.35, alpha: 1),
            UIColor(red: 0.20, green: 0.55, blue: 0.87, alpha: 1),
            UIColor(red: 0.87, green: 0.35, blue: 0.20, alpha: 1),
        ]
        let idx = (ch.id.unicodeScalars.first.map { Int($0.value) } ?? 0) % colors.count
        avatarView.backgroundColor = colors[idx]
        let hasUnread = StoatSocket.shared.unreadChannelIds.contains(ch.id)
        nameLabel.font    = hasUnread ? UIFont.boldSystemFont(ofSize: 16) : UIFont.systemFont(ofSize: 16)
        nameLabel.textColor = hasUnread ? .white : UIColor(white: 0.85, alpha: 1)
        unreadDot.isHidden = !hasUnread
    }
}
