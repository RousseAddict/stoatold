import UIKit

// Server member list with friend request support.
class MembersVC: UIViewController {

    private let server:  StoatServer
    private var members: [MemberEntry] = []
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let spinner   = UIActivityIndicatorView(style: .white)

    struct MemberEntry {
        let userId:   String
        let username: String
        let nickname: String?
        let avatarId: String?
        var relationship: String?   // "Friend" | "Incoming" | "Outgoing" | nil

        // Show the server nickname when present, otherwise the username.
        var displayName: String { return nickname ?? username }
        var avatarURL: String? {
            guard let avatarId = avatarId else { return nil }
            return "https://cdn.stoatusercontent.com/avatars/\(avatarId)"
        }

        var isSelf:    Bool { return userId == StoatSocket.shared.currentUser?.id }
        var isFriend:  Bool { return relationship == "Friend" }
        var isOutgoing: Bool { return relationship == "Outgoing" }
        var isIncoming: Bool { return relationship == "Incoming" }
    }

    init(server: StoatServer) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Members"
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        buildUI()
        fetchMembers()
    }

    private func buildUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height - 64

        spinner.center = CGPoint(x: w / 2, y: h / 2)
        spinner.startAnimating()
        view.addSubview(spinner)

        tableView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        tableView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        tableView.separatorColor  = UIColor(white: 1, alpha: 0.07)
        tableView.rowHeight = 56
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.register(MemberCell.self, forCellReuseIdentifier: "mem")
        tableView.isHidden = true
        view.addSubview(tableView)
    }

    // MARK: - Data

    private func fetchMembers() {
        APIClient.get("/servers/\(server.id)/members") { [weak self] json, err in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            if let err = err { StoatDebug.log("members: fetch error: \(err)"); return }

            var entries: [MemberEntry] = []

            // Revolt-style response: { "members": [...], "users": [...] }
            if let dict = json as? [String: Any] {
                let users = dict["users"] as? [[String: Any]] ?? []
                var userMap: [String: [String: Any]] = [:]
                for u in users { if let id = u["_id"] as? String { userMap[id] = u } }

                let memberList = dict["members"] as? [[String: Any]] ?? []
                for mem in memberList {
                    // member _id may be a string or a dict { "server": ..., "user": ... }
                    let uid: String
                    if let mid = mem["_id"] as? String {
                        uid = mid
                    } else if let mid = mem["_id"] as? [String: Any],
                              let u = mid["user"] as? String {
                        uid = u
                    } else { continue }

                    let userDict  = userMap[uid] ?? [:]
                    let username  = userDict["username"] as? String ?? uid
                    let nickname  = mem["nickname"] as? String
                    // server member avatar takes priority over the global user avatar
                    let avatarId  = ((mem["avatar"] as? [String: Any])?["_id"] as? String)
                        ?? ((userDict["avatar"] as? [String: Any])?["_id"] as? String)
                    let rel       = StoatSocket.shared.allUsers[uid]?.relationship
                    entries.append(MemberEntry(userId: uid, username: username,
                                               nickname: nickname, avatarId: avatarId,
                                               relationship: rel))
                }
            } else if let arr = json as? [[String: Any]] {
                // Flat array fallback
                for u in arr {
                    guard let uid = u["_id"] as? String else { continue }
                    let username = u["username"] as? String ?? uid
                    let avatarId = (u["avatar"] as? [String: Any])?["_id"] as? String
                    let rel      = StoatSocket.shared.allUsers[uid]?.relationship
                    entries.append(MemberEntry(userId: uid, username: username,
                                               nickname: nil, avatarId: avatarId,
                                               relationship: rel))
                }
            }

            // Sort: self first, then friends, then others; alpha within groups
            entries.sort {
                if $0.isSelf != $1.isSelf { return $0.isSelf }
                if $0.isFriend != $1.isFriend { return $0.isFriend }
                return $0.displayName.lowercased() < $1.displayName.lowercased()
            }
            self.members = entries
            self.tableView.isHidden = false
            self.tableView.reloadData()
        }
    }

    // MARK: - Friend actions

    private func sendFriendRequest(to entry: MemberEntry) {
        guard let token = APIClient.sessionToken else { return }
        HTTPClient.request("\(APIClient.baseURL)/users/\(entry.userId)/friend",
                           method: "PUT",
                           headers: ["x-session-token": token]) { [weak self] _, status, _ in
            guard status == 200 || status == 204 || status == 201 else { return }
            let updated = StoatUser(id: entry.userId, username: entry.username,
                                    relationship: "Outgoing")
            StoatSocket.shared.cacheUser(updated)
            if let idx = self?.members.firstIndex(where: { $0.userId == entry.userId }) {
                self?.members[idx].relationship = "Outgoing"
                self?.tableView.reloadRows(at: [IndexPath(row: idx, section: 0)], with: .none)
            }
        }
    }

    private func openDM(with entry: MemberEntry) {
        // Use locally cached channel if we already have a DM with this user
        if let existing = StoatSocket.shared.dmChannels.first(where: {
            $0.recipients.contains(entry.userId)
        }) {
            navigationController?.pushViewController(ChatVC(channel: existing), animated: true)
            return
        }
        guard let token = APIClient.sessionToken else { return }
        HTTPClient.request("\(APIClient.baseURL)/users/\(entry.userId)/dm",
                           method: "GET",
                           headers: ["x-session-token": token]) { [weak self] data, _, _ in
            guard let data = data,
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ch   = StoatChannel.from(dict: dict) else { return }
            StoatSocket.shared.cacheChannel(ch)
            DispatchQueue.main.async {
                self?.navigationController?.pushViewController(ChatVC(channel: ch), animated: true)
            }
        }
    }
}

// MARK: - UITableViewDataSource / Delegate

extension MembersVC: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return members.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "mem", for: indexPath) as! MemberCell
        cell.configure(with: members[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = members[indexPath.row]
        guard !entry.isSelf else { return }

        var actions: [String] = []
        if !entry.isFriend && !entry.isOutgoing { actions.append("Send Friend Request") }
        actions.append("Open DM")

        let sheet = UIActionSheet(title: entry.username, delegate: nil,
                                  cancelButtonTitle: "Cancel",
                                  destructiveButtonTitle: nil)
        for a in actions { sheet.addButton(withTitle: a) }
        // Use a simple block-less approach: store pending entry and show sheet
        self.pendingEntry = entry
        self.pendingActions = actions
        sheet.delegate = self
        sheet.show(in: view)
    }

    // Temp storage for action sheet callback
    private var pendingEntry:   MemberEntry? {
        get { return objc_getAssociatedObject(self, &AssocKeys.entry) as? MemberEntry }
        set { objc_setAssociatedObject(self, &AssocKeys.entry, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    private var pendingActions: [String]? {
        get { return objc_getAssociatedObject(self, &AssocKeys.actions) as? [String] }
        set { objc_setAssociatedObject(self, &AssocKeys.actions, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// Associated object keys
private enum AssocKeys {
    static var entry   = "entry"
    static var actions = "actions"
}

extension MembersVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        guard let entry = pendingEntry,
              let actions = pendingActions else { return }
        pendingEntry   = nil
        pendingActions = nil
        // buttonIndex 0 = cancel, 1+ = actions
        let idx = buttonIndex - 1
        guard idx >= 0 && idx < actions.count else { return }
        switch actions[idx] {
        case "Send Friend Request": sendFriendRequest(to: entry)
        case "Open DM":             openDM(with: entry)
        default: break
        }
    }
}

// MARK: - MemberCell

private class MemberCell: UITableViewCell {

    private let avatarView  = UIView()
    private let avatarLabel = UILabel()
    private let avatarImage = UIImageView()
    private let nameLabel   = UILabel()
    private let badgeLabel  = UILabel()
    private var currentAvatarURL: String?

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

        avatarImage.contentMode   = .scaleAspectFill
        avatarImage.clipsToBounds = true
        avatarImage.frame         = avatarView.bounds
        avatarImage.isHidden      = true
        avatarView.addSubview(avatarImage)

        nameLabel.backgroundColor = .clear
        nameLabel.textColor = .white
        nameLabel.font = UIFont.systemFont(ofSize: 15)
        nameLabel.frame = CGRect(x: 64, y: 12, width: UIScreen.main.bounds.width - 160, height: 20)
        contentView.addSubview(nameLabel)

        badgeLabel.backgroundColor = .clear
        badgeLabel.textAlignment = .right
        badgeLabel.font = UIFont.systemFont(ofSize: 11)
        badgeLabel.frame = CGRect(x: UIScreen.main.bounds.width - 90, y: 14,
                                  width: 78, height: 16)
        contentView.addSubview(badgeLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with entry: MembersVC.MemberEntry) {
        nameLabel.text   = entry.displayName
        avatarLabel.text = String(entry.displayName.prefix(1)).uppercased()
        loadAvatar(entry.avatarURL)

        let colors: [UIColor] = [
            UIColor(red: 0.55, green: 0.27, blue: 0.87, alpha: 1),
            UIColor(red: 0.23, green: 0.65, blue: 0.35, alpha: 1),
            UIColor(red: 0.20, green: 0.55, blue: 0.87, alpha: 1),
            UIColor(red: 0.87, green: 0.35, blue: 0.20, alpha: 1),
        ]
        let idx = (entry.userId.unicodeScalars.first.map { Int($0.value) } ?? 0) % colors.count
        avatarView.backgroundColor = colors[idx]

        if entry.isSelf {
            badgeLabel.text      = "you"
            badgeLabel.textColor = UIColor(white: 0.5, alpha: 1)
        } else if entry.isFriend {
            badgeLabel.text      = "friend"
            badgeLabel.textColor = UIColor(red: 0.23, green: 0.65, blue: 0.35, alpha: 1)
        } else if entry.isOutgoing {
            badgeLabel.text      = "pending"
            badgeLabel.textColor = UIColor(white: 0.5, alpha: 1)
        } else if entry.isIncoming {
            badgeLabel.text      = "wants to add you"
            badgeLabel.textColor = UIColor(red: 0.36, green: 0.56, blue: 0.90, alpha: 1)
        } else {
            badgeLabel.text = ""
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
