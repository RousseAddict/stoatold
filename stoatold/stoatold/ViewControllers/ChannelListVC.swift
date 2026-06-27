import UIKit

class ChannelListVC: UIViewController {

    private let server: StoatServer
    private var textChannels:  [StoatChannel] = []
    private var voiceChannels: [StoatChannel] = []

    private let tableView = UITableView(frame: .zero, style: .plain)

    init(server: StoatServer) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = server.name
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Members", style: .plain,
            target: self, action: #selector(showMembers))
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        buildChannelLists()
        buildUI()
    }

    // MARK: - Data

    private func buildChannelLists() {
        let allCh = StoatSocket.shared.allChannels
        let chs   = server.channelIds.compactMap { allCh[$0] }
        textChannels  = chs.filter { $0.isText  }
        voiceChannels = chs.filter { $0.isVoice }
    }

    // MARK: - UI

    private func buildUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height - 88  // nav bars

        tableView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        tableView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        tableView.separatorColor  = UIColor(white: 1, alpha: 0.07)
        tableView.separatorStyle  = .singleLine
        tableView.rowHeight = 48
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.register(ChannelCell.self, forCellReuseIdentifier: "ch")
        view.addSubview(tableView)

        if textChannels.isEmpty && voiceChannels.isEmpty {
            let lbl = UILabel()
            lbl.backgroundColor = .clear
            lbl.text = "No channels"
            lbl.textColor = UIColor(white: 0.4, alpha: 1)
            lbl.font = UIFont.systemFont(ofSize: 15)
            lbl.textAlignment = .center
            lbl.frame = CGRect(x: 0, y: h/2 - 20, width: w, height: 40)
            view.addSubview(lbl)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Listen for new messages so we can refresh unread dots
        StoatSocket.shared.onNewMessage = { [weak self] _ in
            self?.tableView.reloadData()
        }
        tableView.reloadData()  // refresh unread state on return from ChatVC
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        StoatSocket.shared.onNewMessage = nil
    }

    private func channels(in section: Int) -> [StoatChannel] {
        return section == 0 ? textChannels : voiceChannels
    }

    @objc private func showMembers() {
        navigationController?.pushViewController(MembersVC(server: server), animated: true)
    }
}

// MARK: - UITableViewDataSource / Delegate

extension ChannelListVC: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        var count = 0
        if !textChannels.isEmpty  { count += 1 }
        if !voiceChannels.isEmpty { count += 1 }
        return count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return channels(in: section).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ch", for: indexPath) as! ChannelCell
        cell.configure(with: channels(in: indexPath.section)[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let w = UIScreen.main.bounds.width
        let v = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 30))
        v.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        let lbl = UILabel(frame: CGRect(x: 16, y: 8, width: w - 32, height: 14))
        lbl.backgroundColor = .clear
        lbl.textColor = UIColor(white: 0.45, alpha: 1)
        lbl.font = UIFont.boldSystemFont(ofSize: 11)
        // Which section is which depends on whether textChannels is non-empty
        if textChannels.isEmpty {
            lbl.text = "VOICE CHANNELS"
        } else {
            lbl.text = section == 0 ? "TEXT CHANNELS" : "VOICE CHANNELS"
        }
        v.addSubview(lbl)
        return v
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 30
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // TODO: push ChatVC for text channels
        let ch = channels(in: indexPath.section)[indexPath.row]
        if ch.isVoice {
            navigationController?.pushViewController(VoiceVC(channel: ch), animated: true)
        } else {
            navigationController?.pushViewController(ChatVC(channel: ch), animated: true)
        }
    }
}

// MARK: - ChannelCell

private class ChannelCell: UITableViewCell {

    private let prefixLabel = UILabel()
    private let nameLabel   = UILabel()
    private let unreadDot   = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        selectionStyle  = .default

        let sel = UIView()
        sel.backgroundColor = UIColor(white: 1, alpha: 0.06)
        selectedBackgroundView = sel

        // # or > prefix
        prefixLabel.backgroundColor = .clear
        prefixLabel.textColor = UIColor(white: 0.4, alpha: 1)
        prefixLabel.font = UIFont.boldSystemFont(ofSize: 18)
        prefixLabel.textAlignment = .center
        prefixLabel.frame = CGRect(x: 12, y: 0, width: 28, height: 48)
        contentView.addSubview(prefixLabel)

        // channel name
        nameLabel.backgroundColor = .clear
        nameLabel.textColor = UIColor(white: 0.8, alpha: 1)
        nameLabel.font = UIFont.systemFont(ofSize: 15)
        nameLabel.frame = CGRect(x: 46, y: 0,
                                 width: UIScreen.main.bounds.width - 70, height: 48)
        contentView.addSubview(nameLabel)

        // unread indicator dot
        unreadDot.backgroundColor = UIColor(red: 0.36, green: 0.56, blue: 0.90, alpha: 1)
        unreadDot.layer.cornerRadius = 4
        unreadDot.layer.masksToBounds = true
        unreadDot.frame = CGRect(x: UIScreen.main.bounds.width - 18, y: 20, width: 8, height: 8)
        unreadDot.isHidden = true
        contentView.addSubview(unreadDot)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with channel: StoatChannel) {
        prefixLabel.text = channel.isVoice ? ">" : "#"
        nameLabel.text   = channel.name
        let hasUnread = !channel.isVoice && StoatSocket.shared.unreadChannelIds.contains(channel.id)
        if channel.isVoice {
            nameLabel.textColor = UIColor(red: 0.35, green: 0.75, blue: 0.45, alpha: 1)
            nameLabel.font = UIFont.systemFont(ofSize: 15)
        } else if hasUnread {
            nameLabel.textColor = .white
            nameLabel.font = UIFont.boldSystemFont(ofSize: 15)
        } else {
            nameLabel.textColor = UIColor(white: 0.8, alpha: 1)
            nameLabel.font = UIFont.systemFont(ofSize: 15)
        }
        unreadDot.isHidden = !hasUnread
    }
}
