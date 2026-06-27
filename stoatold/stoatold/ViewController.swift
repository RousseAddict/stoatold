import UIKit

class ServerListVC: UIViewController, UIAlertViewDelegate {
    private var hasBeenReady = false

    private let tableView    = UITableView(frame: .zero, style: .plain)
    private let spinner      = UIActivityIndicatorView(style: .white)
    private let statusLbl    = UILabel()
    private let dmsBadgeView = UIView()
    private let dmsBadgeLbl  = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Servers"
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Logout", style: .plain, target: self, action: #selector(doLogout))
        navigationItem.rightBarButtonItem?.tintColor = UIColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
        buildDMsButton()

        buildUI()
        connectSocket()
        // Tap status label to show debug log without crash
        let tap = UITapGestureRecognizer(target: self, action: #selector(showDebugLog))
        statusLbl.isUserInteractionEnabled = true
        statusLbl.addGestureRecognizer(tap)
    }

    @objc private func showDebugLog() {
        let log = StoatDebug.read()
        let alert = UIAlertView(title: "Debug log", message: log, delegate: self, cancelButtonTitle: "OK")
        alert.addButton(withTitle: "Copy")
        alert.show()
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        if buttonIndex == 1 {
            UIPasteboard.general.string = alertView.message
        }
    }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateDMsBadge()
        StoatSocket.shared.onNewMessage = { [weak self] chId in
            if StoatSocket.shared.allChannels[chId]?.isDirect == true {
                self?.updateDMsBadge()
            } else {
                self?.tableView.reloadData()  // refresh server unread dots
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        StoatSocket.shared.onNewMessage = nil
    }

    // MARK: - UI

    private func buildDMsButton() {
        let btn = UIButton(type: .custom)
        btn.setTitle("DMs", for: .normal)
        btn.setTitleColor(UIColor(white: 0.9, alpha: 1), for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        btn.frame = CGRect(x: 0, y: 0, width: 54, height: 44)
        btn.addTarget(self, action: #selector(showDMs), for: .touchUpInside)

        dmsBadgeView.backgroundColor = UIColor(red: 0.88, green: 0.25, blue: 0.25, alpha: 1)
        dmsBadgeView.layer.cornerRadius = 8
        dmsBadgeView.layer.masksToBounds = true
        dmsBadgeView.frame = CGRect(x: 34, y: 6, width: 16, height: 16)
        dmsBadgeView.isHidden = true

        dmsBadgeLbl.backgroundColor = .clear
        dmsBadgeLbl.textColor = .white
        dmsBadgeLbl.font = UIFont.boldSystemFont(ofSize: 9)
        dmsBadgeLbl.textAlignment = .center
        dmsBadgeLbl.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        dmsBadgeView.addSubview(dmsBadgeLbl)
        btn.addSubview(dmsBadgeView)

        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: btn)
    }

    private func updateDMsBadge() {
        let friendCount = StoatSocket.shared.pendingFriendRequests.count
        let dmUnread    = StoatSocket.shared.unreadChannelIds.filter {
            StoatSocket.shared.allChannels[$0]?.isDirect == true
        }.count
        let total = friendCount + dmUnread
        dmsBadgeView.isHidden = (total == 0)
        dmsBadgeLbl.text = total > 99 ? "99+" : "\(total)"
    }

    private func buildUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height - 44  // minus nav bar

        // Status label (shown while connecting)
        statusLbl.backgroundColor = .clear
        statusLbl.textColor = UIColor(white: 0.5, alpha: 1)
        statusLbl.font = UIFont.systemFont(ofSize: 15)
        statusLbl.textAlignment = .center
        statusLbl.text = "Connecting..."
        statusLbl.frame = CGRect(x: 0, y: h/2 - 30, width: w, height: 20)
        view.addSubview(statusLbl)

        // Spinner
        spinner.frame = CGRect(x: w/2 - 20, y: h/2 - 80, width: 40, height: 40)
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        view.addSubview(spinner)

        // Table view (hidden until Ready)
        tableView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        tableView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        tableView.separatorColor = UIColor(white: 1, alpha: 0.07)
        tableView.separatorStyle = .singleLine
        tableView.rowHeight = 64
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.register(ServerCell.self, forCellReuseIdentifier: "srv")
        tableView.isHidden = true
        view.addSubview(tableView)
    }

    // MARK: - WebSocket

    private func connectSocket() {
        StoatDebug.log("serverlist: connectSocket start")
        statusLbl.text = "Connecting..."
        let ws = StoatSocket.shared
        guard let token = APIClient.sessionToken else { StoatDebug.log("serverlist: no token"); return }

        ws.onReady = { [weak self] in
            StoatDebug.log("serverlist: onReady block entered")
            guard let self = self else { StoatDebug.log("serverlist: self nil"); return }
            self.hasBeenReady = true
            self.statusLbl.text = "onReady: \(StoatSocket.shared.servers.count) servers"
            StoatDebug.log("serverlist: stopping spinner")
            self.spinner.stopAnimating()
            if StoatSocket.shared.servers.isEmpty {
                self.statusLbl.text = "No servers found"
            } else {
                self.statusLbl.isHidden = true
                self.tableView.isHidden = false
                StoatDebug.log("serverlist: reloadData")
                self.tableView.reloadData()
                StoatDebug.log("serverlist: reloadData done")
            }
            self.updateDMsBadge()
        }

        ws.onDisconnect = { [weak self] in
            guard let self = self else { return }
            self.spinner.startAnimating()
            self.tableView.isHidden = true
            self.statusLbl.isHidden = false
            self.statusLbl.text = self.hasBeenReady ? "Connection lost. Reconnecting…" : "Connecting…"
        }

        ws.connect(urlString: APIClient.wsURL, token: token)
    }

    // MARK: - Actions

    @objc private func doLogout() {
        StoatSocket.shared.disconnect(intentional: true)
        APIClient.logout()
        navigationController?.setViewControllers([LoginVC()], animated: true)
    }

    @objc private func showDMs() {
        navigationController?.pushViewController(DMListVC(), animated: true)
    }
}

// MARK: - UITableViewDataSource / Delegate

extension ServerListVC: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return StoatSocket.shared.servers.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "srv", for: indexPath) as! ServerCell
        cell.configure(with: StoatSocket.shared.servers[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let server = StoatSocket.shared.servers[indexPath.row]
        navigationController?.pushViewController(ChannelListVC(server: server), animated: true)
    }
}

// MARK: - ServerCell

private class ServerCell: UITableViewCell {

    private let iconView  = UIView()
    private let iconLabel = UILabel()
    private let nameLabel = UILabel()
    private let unreadDot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        selectionStyle  = .default

        // Highlight color
        let sel = UIView()
        sel.backgroundColor = UIColor(white: 1, alpha: 0.06)
        selectedBackgroundView = sel

        // Squircle icon (Discord-style rounded square)
        iconView.layer.cornerRadius = 16
        iconView.layer.masksToBounds = true
        iconView.frame = CGRect(x: 10, y: 7, width: 50, height: 50)
        contentView.addSubview(iconView)

        iconLabel.backgroundColor = .clear
        iconLabel.textColor = .white
        iconLabel.font = UIFont.boldSystemFont(ofSize: 20)
        iconLabel.textAlignment = .center
        iconLabel.frame = iconView.bounds
        iconView.addSubview(iconLabel)

        // Name
        nameLabel.backgroundColor = .clear
        nameLabel.textColor = .white
        nameLabel.font = UIFont.boldSystemFont(ofSize: 15)
        nameLabel.frame = CGRect(x: 70, y: 0, width: UIScreen.main.bounds.width - 100, height: 64)
        contentView.addSubview(nameLabel)

        unreadDot.backgroundColor = UIColor(red: 0.36, green: 0.56, blue: 0.90, alpha: 1)
        unreadDot.layer.cornerRadius = 4
        unreadDot.layer.masksToBounds = true
        unreadDot.frame = CGRect(x: UIScreen.main.bounds.width - 20, y: 28, width: 8, height: 8)
        unreadDot.isHidden = true
        contentView.addSubview(unreadDot)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with server: StoatServer) {
        nameLabel.text  = server.name
        iconLabel.text  = String(server.name.prefix(1)).uppercased()
        iconView.backgroundColor = ServerListVC.accentColor(for: server.name)
        let hasUnread = server.channelIds.contains { StoatSocket.shared.unreadChannelIds.contains($0) }
        unreadDot.isHidden = !hasUnread
    }

    static func accentColor(for name: String) -> UIColor {
        let palette: [UIColor] = [
            UIColor(red: 0.55, green: 0.27, blue: 0.87, alpha: 1),
            UIColor(red: 0.23, green: 0.65, blue: 0.35, alpha: 1),
            UIColor(red: 0.20, green: 0.55, blue: 0.87, alpha: 1),
            UIColor(red: 0.87, green: 0.35, blue: 0.20, alpha: 1),
            UIColor(red: 0.75, green: 0.55, blue: 0.15, alpha: 1),
        ]
        let idx = (name.unicodeScalars.first.map { Int($0.value) } ?? 0) % palette.count
        return palette[idx]
    }
}

// Expose for ChannelListVC
extension ServerListVC {
    static func accentColor(for name: String) -> UIColor {
        return ServerCell.accentColor(for: name)
    }
}
