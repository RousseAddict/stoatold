import UIKit

class ChatVC: UIViewController {

    private let channel:       StoatChannel
    private var messages:      [StoatMessage] = []

    private let tableView  = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let inputBar   = UIView()
    private let separator  = UIView()
    private let attachBtn  = UIButton(type: .custom)
    private let textField  = UITextField()
    private let sendBtn    = UIButton(type: .custom)
    private let inputH:    CGFloat = 52
    private var pendingAttachId: String?
    private var isLoadingOlder  = false
    private let loadMoreBtn     = UIButton(type: .custom)

    // Typing indicator
    private let typingLabel     = UILabel()
    private var typingUserIds:  Set<String> = []
    private var typingTimers:   [String: Timer] = [:]
    private var sentTyping      = false
    private var typingIdleTimer: Timer?

    // Edit mode
    private let editBar       = UIView()
    private let editLabel     = UILabel()
    private let editCancelBtn = UIButton(type: .custom)
    private var editingMessageId: String?
    private var pendingDeleteId:  String?

    // Reply mode
    private let replyBar       = UIView()
    private let replyLabel     = UILabel()
    private let replyCancelBtn = UIButton(type: .custom)
    private var replyingToId:  String?

    // Jump-to-bottom
    private let jumpBtn   = UIButton(type: .custom)
    private var unseenNew = false

    // Search (list-only, current channel)
    private let searchBar     = UIView()
    private let searchField   = UITextField()
    private let searchCancel  = UIButton(type: .custom)
    private let resultsTable  = UITableView(frame: .zero, style: .plain)
    private let resultsEmpty  = UILabel()
    private let searchSpinner = UIActivityIndicatorView(style: .whiteLarge)
    private var searchResults: [StoatMessage] = []
    private var searchActive  = false
    private let searchBarH: CGFloat = 44

    private lazy var baseH: CGFloat = UIScreen.main.bounds.height - 64

    init(channel: StoatChannel) {
        self.channel = channel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "#\(channel.name)"
        view.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .search, target: self, action: #selector(openSearch))
        buildUI()
        fetchMessages()
        fetchServerMembers()   // seed server nicknames so the thread shows server renames
        StoatSocket.shared.onEvent = { [weak self] json in self?.handleEvent(json) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        StoatSocket.shared.activeChannelId = channel.id
        StoatSocket.shared.markRead(channel.id)
        NotificationCenter.default.addObserver(self, selector: #selector(kbShow(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(kbHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        StoatSocket.shared.activeChannelId = nil
        NotificationCenter.default.removeObserver(self)
        StoatSocket.shared.onEvent = nil
        stopTypingSend()
        for (_, t) in typingTimers { t.invalidate() }
        typingTimers.removeAll()
        typingUserIds.removeAll()
    }

    // MARK: - Build UI

    private func buildUI() {
        let w   = UIScreen.main.bounds.width
        let h   = baseH
        let btn: CGFloat = 34
        let pad: CGFloat = (inputH - btn) / 2

        inputBar.backgroundColor = UIColor(red: 0.14, green: 0.14, blue: 0.18, alpha: 1)
        inputBar.frame = CGRect(x: 0, y: h - inputH, width: w, height: inputH)
        view.addSubview(inputBar)

        separator.backgroundColor = UIColor(white: 1, alpha: 0.09)
        separator.frame = CGRect(x: 0, y: 0, width: w, height: 1)
        inputBar.addSubview(separator)

        // attach + button (left)
        attachBtn.backgroundColor = UIColor(white: 1, alpha: 0.08)
        attachBtn.setTitle("+", for: .normal)
        attachBtn.setTitleColor(UIColor(white: 0.65, alpha: 1), for: .normal)
        attachBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 20)
        attachBtn.layer.cornerRadius = btn / 2
        attachBtn.layer.masksToBounds = true
        attachBtn.frame = CGRect(x: pad + 2, y: pad - 2, width: btn, height: btn)
        attachBtn.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        inputBar.addSubview(attachBtn)

        // send button (right)
        sendBtn.backgroundColor = UIColor(red: 0.36, green: 0.56, blue: 0.90, alpha: 1)
        sendBtn.setTitle("\u{2191}", for: .normal)
        sendBtn.setTitleColor(.white, for: .normal)
        sendBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        sendBtn.layer.cornerRadius = btn / 2
        sendBtn.layer.masksToBounds = true
        sendBtn.titleEdgeInsets = UIEdgeInsets(top: -2, left: 3, bottom: 2, right: -3)
        sendBtn.frame = CGRect(x: w - pad - btn, y: pad, width: btn, height: btn)
        sendBtn.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        inputBar.addSubview(sendBtn)

        // text field (between attach and send)
        textField.backgroundColor = UIColor(red: 0.20, green: 0.20, blue: 0.26, alpha: 1)
        textField.textColor = .white
        textField.layer.cornerRadius = 8
        textField.layer.masksToBounds = true
        textField.contentVerticalAlignment = .center
        let lpad = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: btn))
        textField.leftView = lpad; textField.leftViewMode = .always
        let rpad2 = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: btn))
        textField.rightView = rpad2; textField.rightViewMode = .always
        let tfX: CGFloat = pad + btn + pad
        let tfW: CGFloat = w - tfX - pad - btn - pad
        textField.frame = CGRect(x: tfX, y: pad, width: tfW, height: btn)
        textField.returnKeyType = .send
        textField.delegate = self
        textField.placeholder = "Message #\(channel.name)"
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        inputBar.addSubview(textField)

        tableView.frame = CGRect(x: 0, y: 0, width: w, height: h - inputH)
        tableView.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.register(MessageCell.self, forCellReuseIdentifier: "msg")
        view.addSubview(tableView)

        emptyLabel.backgroundColor = .clear
        emptyLabel.text = "No messages yet"
        emptyLabel.textColor = UIColor(white: 0.4, alpha: 1)
        emptyLabel.font = UIFont.systemFont(ofSize: 15)
        emptyLabel.textAlignment = .center
        emptyLabel.frame = CGRect(x: 0, y: (h - inputH) / 3, width: w, height: 30)
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false  // allow swipe-to-delete to coexist
        tableView.addGestureRecognizer(tap)

        loadMoreBtn.setTitle("Load older messages", for: .normal)
        loadMoreBtn.setTitleColor(UIColor(white: 0.55, alpha: 1), for: .normal)
        loadMoreBtn.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        loadMoreBtn.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 40)
        loadMoreBtn.addTarget(self, action: #selector(loadOlderMessages), for: .touchUpInside)
        tableView.tableHeaderView = loadMoreBtn

        typingLabel.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 0.92)
        typingLabel.textColor = UIColor(white: 0.55, alpha: 1)
        typingLabel.font = UIFont.italicSystemFont(ofSize: 12)
        typingLabel.isHidden = true
        view.addSubview(typingLabel)
        layoutTypingLabel()

        // Edit banner (shown above input bar while editing a message)
        editBar.backgroundColor = UIColor(red: 0.18, green: 0.18, blue: 0.24, alpha: 1)
        editBar.isHidden = true
        editLabel.backgroundColor = .clear
        editLabel.textColor = UIColor(white: 0.7, alpha: 1)
        editLabel.font = UIFont.systemFont(ofSize: 12)
        editLabel.text = "Editing message"
        editBar.addSubview(editLabel)
        editCancelBtn.setTitle("\u{2715} Cancel", for: .normal)
        editCancelBtn.setTitleColor(UIColor(red: 0.90, green: 0.45, blue: 0.45, alpha: 1), for: .normal)
        editCancelBtn.titleLabel?.font = UIFont.systemFont(ofSize: 12)
        editCancelBtn.addTarget(self, action: #selector(cancelEdit), for: .touchUpInside)
        editBar.addSubview(editCancelBtn)
        view.addSubview(editBar)
        layoutEditBar()

        // Reply banner (shown above input bar while replying to a message)
        replyBar.backgroundColor = UIColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1)
        replyBar.isHidden = true
        replyLabel.backgroundColor = .clear
        replyLabel.textColor = UIColor(white: 0.7, alpha: 1)
        replyLabel.font = UIFont.systemFont(ofSize: 12)
        replyBar.addSubview(replyLabel)
        replyCancelBtn.setTitle("\u{2715} Cancel", for: .normal)
        replyCancelBtn.setTitleColor(UIColor(red: 0.90, green: 0.45, blue: 0.45, alpha: 1), for: .normal)
        replyCancelBtn.titleLabel?.font = UIFont.systemFont(ofSize: 12)
        replyCancelBtn.addTarget(self, action: #selector(cancelReply), for: .touchUpInside)
        replyBar.addSubview(replyCancelBtn)
        view.addSubview(replyBar)
        layoutReplyBar()

        // Jump-to-bottom pill (shown when scrolled up / new msg arrives off-screen)
        jumpBtn.backgroundColor = UIColor(red: 0.18, green: 0.18, blue: 0.24, alpha: 0.95)
        jumpBtn.setTitleColor(UIColor(red: 0.55, green: 0.70, blue: 0.98, alpha: 1), for: .normal)
        jumpBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        jumpBtn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        jumpBtn.layer.cornerRadius = 15
        jumpBtn.layer.masksToBounds = true
        jumpBtn.isHidden = true
        jumpBtn.addTarget(self, action: #selector(jumpTapped), for: .touchUpInside)
        view.addSubview(jumpBtn)
        layoutJumpButton()

        buildSearchUI()
    }

    private func buildSearchUI() {
        let w = UIScreen.main.bounds.width
        let h = baseH

        // Results table fills the area below the search bar; hidden until searching.
        resultsTable.frame = CGRect(x: 0, y: searchBarH, width: w, height: h - searchBarH)
        resultsTable.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        resultsTable.separatorStyle = .none
        resultsTable.dataSource = self
        resultsTable.delegate   = self
        resultsTable.register(MessageCell.self, forCellReuseIdentifier: "msg")
        resultsTable.isHidden = true
        view.addSubview(resultsTable)

        // Tap anywhere in the results area dismisses the keyboard (cell taps still work).
        let searchTap = UITapGestureRecognizer(target: self, action: #selector(dismissSearchKeyboard))
        searchTap.cancelsTouchesInView = false
        resultsTable.addGestureRecognizer(searchTap)

        resultsEmpty.backgroundColor = .clear
        resultsEmpty.text = "No results"
        resultsEmpty.textColor = UIColor(white: 0.4, alpha: 1)
        resultsEmpty.font = UIFont.systemFont(ofSize: 15)
        resultsEmpty.textAlignment = .center
        resultsEmpty.frame = CGRect(x: 0, y: (h - searchBarH) / 3, width: w, height: 30)
        resultsEmpty.isHidden = true
        view.addSubview(resultsEmpty)

        // Search bar overlay pinned to the top; hidden until the magnifier is tapped.
        searchBar.backgroundColor = UIColor(red: 0.14, green: 0.14, blue: 0.18, alpha: 1)
        searchBar.frame = CGRect(x: 0, y: 0, width: w, height: searchBarH)
        searchBar.isHidden = true

        let sep = UIView(frame: CGRect(x: 0, y: searchBarH - 1, width: w, height: 1))
        sep.backgroundColor = UIColor(white: 1, alpha: 0.09)
        searchBar.addSubview(sep)

        let cancelW: CGFloat = 64
        searchField.backgroundColor = UIColor(red: 0.20, green: 0.20, blue: 0.26, alpha: 1)
        searchField.textColor = .white
        searchField.layer.cornerRadius = 8
        searchField.layer.masksToBounds = true
        searchField.contentVerticalAlignment = .center
        let lpad = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 32))
        searchField.leftView = lpad; searchField.leftViewMode = .always
        searchField.frame = CGRect(x: 10, y: 6, width: w - 20 - cancelW, height: 32)
        searchField.returnKeyType = .search
        searchField.placeholder = "Search #\(channel.name)"
        searchField.delegate = self
        searchBar.addSubview(searchField)

        searchCancel.setTitle("Cancel", for: .normal)
        searchCancel.setTitleColor(UIColor(red: 0.55, green: 0.70, blue: 0.98, alpha: 1), for: .normal)
        searchCancel.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        searchCancel.frame = CGRect(x: w - cancelW - 4, y: 6, width: cancelW, height: 32)
        searchCancel.addTarget(self, action: #selector(closeSearch), for: .touchUpInside)
        searchBar.addSubview(searchCancel)

        view.addSubview(searchBar)

        // Spinner sits just below the search bar so the keyboard never covers it.
        searchSpinner.hidesWhenStopped = true
        searchSpinner.center = CGPoint(x: w / 2, y: searchBarH + 40)
        view.addSubview(searchSpinner)
    }

    @objc private func dismissSearchKeyboard() { searchField.resignFirstResponder() }

    @objc private func openSearch() {
        searchActive = true
        searchResults = []
        resultsEmpty.isHidden = true
        resultsTable.reloadData()
        searchBar.isHidden = false
        resultsTable.isHidden = false
        view.bringSubviewToFront(resultsTable)
        view.bringSubviewToFront(resultsEmpty)
        view.bringSubviewToFront(searchBar)
        view.bringSubviewToFront(searchSpinner)
        searchField.becomeFirstResponder()
    }

    @objc private func closeSearch() {
        searchActive = false
        searchSpinner.stopAnimating()
        searchField.resignFirstResponder()
        searchField.text = ""
        searchBar.isHidden = true
        resultsTable.isHidden = true
        resultsEmpty.isHidden = true
        searchResults = []
        resultsTable.reloadData()
    }

    private func performSearch() {
        let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 1 && query.count <= 64 else { return }
        guard let token = APIClient.sessionToken,
              let body  = try? JSONSerialization.data(withJSONObject: [
                  "query": query,
                  "limit": 50,
                  "sort": "Relevance",
                  "include_users": true,
              ]) else { return }
        // Dismiss the keyboard and show the spinner (clear old results so it stands alone).
        searchField.resignFirstResponder()
        searchResults = []
        resultsEmpty.isHidden = true
        resultsTable.reloadData()
        searchSpinner.startAnimating()
        view.bringSubviewToFront(searchSpinner)
        HTTPClient.request("\(APIClient.baseURL)/channels/\(channel.id)/search",
                           method: "POST", headers: ["x-session-token": token], body: body) { [weak self] data, status, err in
            guard let self = self else { return }
            self.searchSpinner.stopAnimating()
            if let err = err { StoatDebug.log("search: error \(err.localizedDescription)"); return }
            guard let data = data,
                  let obj  = try? JSONSerialization.jsonObject(with: data) else {
                StoatDebug.log("search: bad response status=\(status)")
                return
            }
            // Response is either a bare [Message] or { messages, users, members }.
            var rawMessages: [[String: Any]] = []
            if let arr = obj as? [[String: Any]] {
                rawMessages = arr
            } else if let dict = obj as? [String: Any] {
                rawMessages = dict["messages"] as? [[String: Any]] ?? []
                if let users = dict["users"] as? [[String: Any]] {
                    for u in users { if let user = StoatUser.from(dict: u) { StoatSocket.shared.cacheUser(user) } }
                }
            }
            self.searchResults = rawMessages.compactMap { StoatMessage.from(dict: $0) }
            self.resultsEmpty.isHidden = !self.searchResults.isEmpty
            self.resultsTable.reloadData()
            if !self.searchResults.isEmpty {
                self.resultsTable.setContentOffset(.zero, animated: false)
            }
        }
    }

    private func layoutJumpButton() {
        let w = UIScreen.main.bounds.width
        jumpBtn.sizeToFit()
        let bw = jumpBtn.bounds.width
        let bh: CGFloat = 30
        jumpBtn.frame = CGRect(x: w - bw - 12,
                               y: inputBar.frame.minY - bh - 24,
                               width: bw, height: bh)
    }

    private func isNearBottom() -> Bool {
        let off = tableView.contentOffset.y + tableView.bounds.height
        return off >= tableView.contentSize.height - 80
    }

    private func updateJumpButton() {
        if isNearBottom() {
            unseenNew = false
            jumpBtn.isHidden = true
            return
        }
        jumpBtn.setTitle(unseenNew ? "\u{2193} New messages" : "\u{2193}", for: .normal)
        jumpBtn.isHidden = false
        layoutJumpButton()
    }

    @objc private func jumpTapped() {
        unseenNew = false
        jumpBtn.isHidden = true
        scrollToBottom()
    }

    private func layoutTypingLabel() {
        let w = UIScreen.main.bounds.width
        typingLabel.frame = CGRect(x: 12, y: inputBar.frame.minY - 18, width: w - 24, height: 18)
        if !typingLabel.isHidden { view.bringSubviewToFront(typingLabel) }
    }

    private func layoutEditBar() {
        let w = UIScreen.main.bounds.width
        editBar.frame       = CGRect(x: 0, y: inputBar.frame.minY - 30, width: w, height: 30)
        editLabel.frame     = CGRect(x: 12, y: 0, width: w - 100, height: 30)
        editCancelBtn.frame = CGRect(x: w - 92, y: 0, width: 80, height: 30)
        if !editBar.isHidden { view.bringSubviewToFront(editBar) }
    }

    private func layoutReplyBar() {
        let w = UIScreen.main.bounds.width
        replyBar.frame       = CGRect(x: 0, y: inputBar.frame.minY - 30, width: w, height: 30)
        replyLabel.frame     = CGRect(x: 12, y: 0, width: w - 100, height: 30)
        replyCancelBtn.frame = CGRect(x: w - 92, y: 0, width: 80, height: 30)
        if !replyBar.isHidden { view.bringSubviewToFront(replyBar) }
    }

    // MARK: - Keyboard

    @objc private func dismissKeyboard() { textField.resignFirstResponder() }

    @objc private func kbShow(_ n: Notification) {
        guard let info = n.userInfo,
              let kbFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let dur = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue
        else { return }
        let kbH = kbFrame.height; let w = UIScreen.main.bounds.width; let h = baseH
        UIView.animate(withDuration: dur) {
            self.inputBar.frame  = CGRect(x: 0, y: h - self.inputH - kbH, width: w, height: self.inputH)
            self.tableView.frame = CGRect(x: 0, y: 0, width: w, height: h - self.inputH - kbH)
            self.layoutTypingLabel()
            self.layoutEditBar()
            self.layoutReplyBar()
            self.layoutJumpButton()
        }
        scrollToBottom()
    }

    @objc private func kbHide(_ n: Notification) {
        guard let info = n.userInfo,
              let dur = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue
        else { return }
        let w = UIScreen.main.bounds.width; let h = baseH
        UIView.animate(withDuration: dur) {
            self.inputBar.frame  = CGRect(x: 0, y: h - self.inputH, width: w, height: self.inputH)
            self.tableView.frame = CGRect(x: 0, y: 0, width: w, height: h - self.inputH)
            self.layoutTypingLabel()
            self.layoutEditBar()
            self.layoutReplyBar()
            self.layoutJumpButton()
        }
    }

    // MARK: - Data

    private func fetchMessages() {
        APIClient.get("/channels/\(channel.id)/messages?limit=50") { [weak self] json, err in
            guard let self = self else { return }
            if let err = err { StoatDebug.log("chat: fetch error: \(err)"); return }
            if let arr = json as? [[String: Any]] {
                self.messages = arr.compactMap { StoatMessage.from(dict: $0) }.reversed()
            }
            self.tableView.reloadData()
            self.emptyLabel.isHidden = !self.messages.isEmpty
            self.scrollToBottom(animated: false)
            self.resolveUnknownAuthors()
        }
    }

    // Fetch this server's members to populate nicknames (mirrors MembersVC), so authorName
    // shows the server-specific rename instead of the global username. No-op for DMs.
    private func fetchServerMembers() {
        guard let serverId = channel.serverId else { return }
        APIClient.get("/servers/\(serverId)/members") { [weak self] json, err in
            guard let self = self else { return }
            if let err = err { StoatDebug.log("chat: members fetch error: \(err)"); return }
            guard let dict = json as? [String: Any],
                  let memberList = dict["members"] as? [[String: Any]] else { return }
            // Cache any embedded users too so unknown authors resolve.
            if let users = dict["users"] as? [[String: Any]] {
                for u in users { if let user = StoatUser.from(dict: u) { StoatSocket.shared.cacheUser(user) } }
            }
            for mem in memberList {
                let uid: String
                if let mid = mem["_id"] as? String {
                    uid = mid
                } else if let mid = mem["_id"] as? [String: Any],
                          let u = mid["user"] as? String {
                    uid = u
                } else { continue }
                if let nick = mem["nickname"] as? String, !nick.isEmpty {
                    StoatSocket.shared.cacheServerNickname(serverId: serverId, userId: uid, nickname: nick)
                }
            }
            self.tableView.reloadData()
        }
    }

    private func resolveUnknownAuthors() {
        let unknown = Array(Set(messages
            .filter { $0.displayName == nil && StoatSocket.shared.allUsers[$0.authorId] == nil }
            .map { $0.authorId }))
        guard !unknown.isEmpty else { return }
        var pending = unknown.count
        for uid in unknown {
            APIClient.get("/users/\(uid)") { [weak self] json, _ in
                if let dict = json as? [String: Any], let u = StoatUser.from(dict: dict) {
                    StoatSocket.shared.cacheUser(u)
                }
                pending -= 1
                if pending == 0 { self?.tableView.reloadData() }
            }
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }
        StoatDebug.log("event: type=\(type) ch=\(json["channel"] as? String ?? json["id"] as? String ?? "?")")
        switch type {
        case "Message":            handleNewMessage(json)
        case "MessageUpdate":      handleMessageUpdate(json)
        case "MessageDelete":      handleMessageDelete(json)
        case "ChannelStartTyping": handleTyping(json, started: true)
        case "ChannelStopTyping":  handleTyping(json, started: false)
        default:                   break
        }
    }

    private func handleNewMessage(_ json: [String: Any]) {
        guard let chId = json["channel"] as? String, chId == channel.id else { return }
        guard let msg = StoatMessage.from(dict: json) else {
            StoatDebug.log("event: Message parse failed keys=\(Array(json.keys))")
            return
        }
        guard !messages.contains(where: { $0.id == msg.id }) else { return }
        removeTyping(msg.authorId)   // sending a message implicitly stops typing
        let wasNearBottom = isNearBottom() || msg.authorId == StoatSocket.shared.currentUser?.id
        messages.append(msg)
        emptyLabel.isHidden = true
        tableView.insertRows(at: [IndexPath(row: messages.count - 1, section: 0)], with: .none)
        if wasNearBottom {
            scrollToBottom()
        } else {
            unseenNew = true
            updateJumpButton()
        }
        if msg.displayName == nil && StoatSocket.shared.allUsers[msg.authorId] == nil {
            APIClient.get("/users/\(msg.authorId)") { [weak self] json, _ in
                if let dict = json as? [String: Any], let u = StoatUser.from(dict: dict) {
                    StoatSocket.shared.cacheUser(u); self?.tableView.reloadData()
                }
            }
        }
    }

    private func handleMessageUpdate(_ json: [String: Any]) {
        guard let chId = json["channel"] as? String, chId == channel.id,
              let mid  = json["id"] as? String,
              let data = json["data"] as? [String: Any],
              let idx  = messages.firstIndex(where: { $0.id == mid }) else { return }
        if let newContent = data["content"] as? String { messages[idx].content = newContent }
        if data["edited"] != nil { messages[idx].edited = true }
        tableView.reloadRows(at: [IndexPath(row: idx, section: 0)], with: .none)
    }

    private func handleMessageDelete(_ json: [String: Any]) {
        guard let chId = json["channel"] as? String, chId == channel.id,
              let mid  = json["id"] as? String,
              let idx  = messages.firstIndex(where: { $0.id == mid }) else { return }
        messages.remove(at: idx)
        // reloadData (not deleteRows) so the following message re-evaluates grouping/separator
        // now that its predecessor changed.
        tableView.reloadData()
        emptyLabel.isHidden = !messages.isEmpty
    }

    // MARK: - Typing indicator (receive)

    private func handleTyping(_ json: [String: Any], started: Bool) {
        let chId = json["id"] as? String ?? json["channel"] as? String
        guard chId == channel.id,
              let uid = json["user"] as? String,
              uid != StoatSocket.shared.currentUser?.id else { return }
        if started { addTyping(uid) } else { removeTyping(uid) }
    }

    private func addTyping(_ uid: String) {
        typingUserIds.insert(uid)
        typingTimers[uid]?.invalidate()
        let t = Timer(timeInterval: 8, target: self, selector: #selector(typingTimedOut(_:)),
                      userInfo: uid, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        typingTimers[uid] = t
        if StoatSocket.shared.allUsers[uid] == nil {
            APIClient.get("/users/\(uid)") { [weak self] json, _ in
                if let dict = json as? [String: Any], let u = StoatUser.from(dict: dict) {
                    StoatSocket.shared.cacheUser(u); self?.updateTypingLabel()
                }
            }
        }
        updateTypingLabel()
    }

    private func removeTyping(_ uid: String) {
        guard typingUserIds.contains(uid) else { return }
        typingUserIds.remove(uid)
        typingTimers[uid]?.invalidate(); typingTimers[uid] = nil
        updateTypingLabel()
    }

    @objc private func typingTimedOut(_ t: Timer) {
        if let uid = t.userInfo as? String { removeTyping(uid) }
    }

    private func updateTypingLabel() {
        let names = typingUserIds.compactMap { StoatSocket.shared.allUsers[$0]?.username }
        let text: String
        switch typingUserIds.count {
        case 0:  text = ""
        case 1:  text = "\(names.first ?? "Someone") is typing…"
        case 2 where names.count == 2:
                 text = "\(names[0]) and \(names[1]) are typing…"
        default: text = "Several people are typing…"
        }
        typingLabel.text = text
        typingLabel.isHidden = text.isEmpty
        layoutTypingLabel()
    }

    // MARK: - Typing indicator (send)

    @objc private func textChanged() {
        if editingMessageId != nil { return }   // no typing broadcasts while editing
        let empty = (textField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if empty { stopTypingSend(); return }
        if !sentTyping {
            StoatSocket.shared.sendJSON(["type": "BeginTyping", "channel": channel.id])
            sentTyping = true
        }
        typingIdleTimer?.invalidate()
        let t = Timer(timeInterval: 4, target: self, selector: #selector(typingIdle),
                      userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        typingIdleTimer = t
    }

    @objc private func typingIdle() { stopTypingSend() }

    private func stopTypingSend() {
        typingIdleTimer?.invalidate(); typingIdleTimer = nil
        guard sentTyping else { return }
        StoatSocket.shared.sendJSON(["type": "EndTyping", "channel": channel.id])
        sentTyping = false
    }

    // MARK: - Edit / delete own message

    private func beginEdit(messageId: String, content: String) {
        stopTypingSend()
        if replyingToId != nil { endReplyMode() }
        editingMessageId = messageId
        textField.text = content
        typingLabel.isHidden = true
        editBar.isHidden = false
        sendBtn.setTitle("\u{2713}", for: .normal)   // ✓ save
        layoutEditBar()
        textField.becomeFirstResponder()
    }

    private func endEditMode() {
        editingMessageId = nil
        textField.text = ""
        editBar.isHidden = true
        sendBtn.setTitle("\u{2191}", for: .normal)   // ↑ send
    }

    @objc private func cancelEdit() { endEditMode() }

    // MARK: - Reply

    private func beginReply(messageId: String, author: String, preview: String) {
        if editingMessageId != nil { endEditMode() }
        replyingToId = messageId
        replyLabel.text = "Replying to \(author): \(preview)"
        replyBar.isHidden = false
        layoutReplyBar()
        textField.becomeFirstResponder()
    }

    private func endReplyMode() {
        replyingToId = nil
        replyBar.isHidden = true
    }

    @objc private func cancelReply() { endReplyMode() }

    /// Short one-line preview of a message's content for reply banners/labels.
    fileprivate static func previewText(_ content: String, attachment: Bool) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return attachment ? "[image]" : "[no text]" }
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count > 60 {
            let idx = oneLine.index(oneLine.startIndex, offsetBy: 60)
            return String(oneLine[..<idx]) + "\u{2026}"
        }
        return oneLine
    }

    /// The "↱ author: preview" line to show above a message that is a reply, or nil.
    private func replyDisplay(for msg: StoatMessage) -> String? {
        guard let rid = msg.replies.first else { return nil }
        if let target = messages.first(where: { $0.id == rid }) {
            let preview = ChatVC.previewText(target.content, attachment: !target.attachments.isEmpty)
            return "\u{21B1} \(target.authorName): \(preview)"
        }
        return "\u{21B1} Reply"
    }

    private func saveEdit(_ mid: String, content: String) {
        guard let token = APIClient.sessionToken,
              let body  = try? JSONSerialization.data(withJSONObject: ["content": content]) else { return }
        HTTPClient.request("\(APIClient.baseURL)/channels/\(channel.id)/messages/\(mid)",
                           method: "PATCH", headers: ["x-session-token": token], body: body) { [weak self] _, status, err in
            guard let self = self else { return }
            if let err = err { StoatDebug.log("chat: edit error: \(err.localizedDescription)"); return }
            StoatDebug.log("chat: edit status=\(status)")
            // Optimistic local update; server MessageUpdate reconciles + marks edited.
            if let idx = self.messages.firstIndex(where: { $0.id == mid }) {
                self.messages[idx].content = content
                self.messages[idx].edited  = true
                self.tableView.reloadRows(at: [IndexPath(row: idx, section: 0)], with: .none)
            }
        }
    }

    private func confirmDelete(_ mid: String) {
        pendingDeleteId = mid
        // Build via property/addButton API — the Swift variadic
        // UIAlertView(…otherButtonTitles:) initializer crashes at bind time on iOS 6.
        let a = UIAlertView()
        a.title    = "Delete message?"
        a.delegate = self
        a.addButton(withTitle: "Cancel")   // index 0
        a.addButton(withTitle: "Delete")   // index 1
        a.cancelButtonIndex = 0
        a.show()
    }

    private func deleteMessage(_ mid: String) {
        guard let token = APIClient.sessionToken else { return }
        HTTPClient.request("\(APIClient.baseURL)/channels/\(channel.id)/messages/\(mid)",
                           method: "DELETE", headers: ["x-session-token": token]) { [weak self] _, status, _ in
            guard let self = self, status == 204 || status == 200 else { return }
            if self.editingMessageId == mid { self.endEditMode() }
            if let idx = self.messages.firstIndex(where: { $0.id == mid }) {
                self.messages.remove(at: idx)
                self.tableView.reloadData()   // recompute neighbour grouping/separators
                self.emptyLabel.isHidden = !self.messages.isEmpty
            }
        }
    }

    private func scrollToBottom(animated: Bool = true) {
        guard !messages.isEmpty else { return }
        tableView.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0),
                              at: .bottom, animated: animated)
    }


    @objc private func loadOlderMessages() {
        guard !isLoadingOlder, let firstId = messages.first?.id else { return }
        isLoadingOlder = true
        loadMoreBtn.setTitle("Loading…", for: .normal)
        APIClient.get("/channels/\(channel.id)/messages?limit=50&before=\(firstId)") { [weak self] json, err in
            guard let self = self else { return }
            self.isLoadingOlder = false
            if let arr = json as? [[String: Any]] {
                let older = arr.compactMap { StoatMessage.from(dict: $0) }.reversed() as [StoatMessage]
                if older.isEmpty {
                    self.loadMoreBtn.setTitle("No more messages", for: .normal)
                    self.loadMoreBtn.isEnabled = false
                    return
                }
                // Preserve scroll position while prepending
                let prevOffset = self.tableView.contentOffset
                let prevH      = self.tableView.contentSize.height
                self.messages  = older + self.messages
                self.tableView.reloadData()
                let newH = self.tableView.contentSize.height
                self.tableView.contentOffset = CGPoint(x: 0, y: prevOffset.y + (newH - prevH))
            }
            self.loadMoreBtn.setTitle("Load older messages", for: .normal)
        }
    }

    // MARK: - Attach

    @objc private func attachTapped() {
        // Tap again to clear pending attachment
        if pendingAttachId != nil {
            pendingAttachId = nil
            attachBtn.setTitle("+", for: .normal)
            attachBtn.backgroundColor = UIColor(white: 1, alpha: 0.08)
            return
        }
        let src: UIImagePickerController.SourceType =
            UIImagePickerController.isSourceTypeAvailable(.photoLibrary) ? .photoLibrary : .camera
        let picker = UIImagePickerController()
        picker.delegate    = self
        picker.sourceType  = src
        picker.allowsEditing = false
        present(picker, animated: true)
    }

    private func uploadImage(_ image: UIImage) {
        guard let token = APIClient.sessionToken else { return }
        // Resize to max 1600px wide before uploading
        let maxW: CGFloat = 1600
        let scale = image.size.width > maxW ? maxW / image.size.width : 1.0
        let target: UIImage
        if scale < 1.0 {
            let sz = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(sz, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: sz))
            target = UIGraphicsGetImageFromCurrentImageContext() ?? image
            UIGraphicsEndImageContext()
        } else {
            target = image
        }
        guard let data = target.jpegData(compressionQuality: 0.82) else { return }

        attachBtn.setTitle("0%", for: .normal)
        attachBtn.isEnabled = false

        HTTPClient.upload("https://cdn.stoatusercontent.com/attachments",
                          fileData: data, filename: "image.jpg", mimeType: "image/jpeg",
                          headers: ["x-session-token": token],
                          progress: { [weak self] sent, total in
                              let pct = total > 0 ? Int(Double(sent)/Double(total)*100) : 0
                              self?.attachBtn.setTitle("\(pct)%", for: .normal)
                          }) { [weak self] respData, status, _ in
            guard let self = self else { return }
            self.attachBtn.isEnabled = true
            if let respData = respData,
               let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
               let id = json["id"] as? String {
                self.pendingAttachId = id
                self.attachBtn.setTitle("✓", for: .normal)
                self.attachBtn.backgroundColor = UIColor(red: 0.23, green: 0.65, blue: 0.35, alpha: 0.5)
            } else {
                StoatDebug.log("upload: failed status=\(status)")
                self.attachBtn.setTitle("+", for: .normal)
            }
        }
    }

    // MARK: - Send

    @objc private func sendTapped() {
        let text = textField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        if let mid = editingMessageId {
            guard !text.isEmpty else { return }   // empty edit → ignore (use Cancel to abort)
            endEditMode()
            saveEdit(mid, content: text)
            return
        }
        guard !text.isEmpty || pendingAttachId != nil else { return }
        textField.text = ""
        stopTypingSend()

        var replies: [[String: Any]] = []
        if let rid = replyingToId {
            replies = [["id": rid, "mention": false]]
            endReplyMode()
        }
        var payload: [String: Any] = ["content": text, "replies": replies]
        if let aid = pendingAttachId {
            payload["attachments"] = [aid]
            pendingAttachId = nil
            attachBtn.setTitle("+", for: .normal)
            attachBtn.backgroundColor = UIColor(white: 1, alpha: 0.08)
        }
        guard let token = APIClient.sessionToken,
              let body  = try? JSONSerialization.data(withJSONObject: payload) else { return }
        HTTPClient.request("\(APIClient.baseURL)/channels/\(channel.id)/messages",
                           method: "POST", headers: ["x-session-token": token], body: body) { [weak self] data, _, err in
            if let err = err { StoatDebug.log("chat: send error: \(err.localizedDescription)"); return }
            guard let self = self,
                  let data = data,
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let msg  = StoatMessage.from(dict: dict),
                  !self.messages.contains(where: { $0.id == msg.id }) else { return }
            self.messages.append(msg)
            self.tableView.insertRows(at: [IndexPath(row: self.messages.count - 1, section: 0)], with: .none)
            self.scrollToBottom()
        }
    }

    // MARK: - Grouping & date separators

    private static let daySepFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"; return f
    }()

    // Calendar day key (yyyymmdd) via NSCalendar.components — iOS 2+ safe
    // (Calendar.isDate(_:inSameDayAs:) / component(_:from:) are iOS 8+).
    private func dayKey(_ d: Date) -> Int {
        let c = (Calendar.current as NSCalendar).components([.year, .month, .day], from: d)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    private func dayLabel(_ d: Date) -> String {
        let k = dayKey(d)
        if k == dayKey(Date())                              { return "Today" }
        if k == dayKey(Date(timeIntervalSinceNow: -86400))  { return "Yesterday" }
        return ChatVC.daySepFmt.string(from: d)
    }

    /// Returns the separator text to show ABOVE this row, or nil if none (same day as prev).
    private func daySeparatorText(at idx: Int) -> String? {
        guard idx >= 0, idx < messages.count, let d = messages[idx].timestamp else { return nil }
        if idx == 0 { return dayLabel(d) }
        guard let pd = messages[idx - 1].timestamp else { return dayLabel(d) }
        return dayKey(d) != dayKey(pd) ? dayLabel(d) : nil
    }

    /// True when this row continues a group: same author as prev, within 5 min, same day.
    private func isGrouped(at idx: Int) -> Bool {
        guard idx > 0, idx < messages.count else { return false }
        let msg = messages[idx], prev = messages[idx - 1]
        guard prev.authorId == msg.authorId,
              let d = msg.timestamp, let pd = prev.timestamp,
              d.timeIntervalSince(pd) < 300 else { return false }
        return daySeparatorText(at: idx) == nil
    }

    // MARK: - Row height

    private static let sizer: UILabel = {
        let l = UILabel(); l.font = UIFont.systemFont(ofSize: 14); l.numberOfLines = 0; return l
    }()

    fileprivate static func rowHeight(for msg: StoatMessage, grouped: Bool, separator: Bool, hasReply: Bool) -> CGFloat {
        let w = UIScreen.main.bounds.width - 24
        let resolved = MessageCell.resolveMentions(msg.content).0
        let base = resolved.isEmpty ? " " : resolved
        sizer.text = base + (msg.edited ? "  (edited)" : "")
        let textH = ceil(sizer.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height)
        var h = grouped ? max(30, textH + 18) : max(56, textH + 42)
        if let att = msg.attachments.first, att.isImage {
            if att.width > 0 {
                h += min(220, CGFloat(att.height) * w / CGFloat(att.width)) + 8
            } else {
                h += 180
            }
        }
        if separator { h += 30 }
        if hasReply  { h += 18 }
        return h
    }
}

// MARK: - UITextFieldDelegate

extension ChatVC: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === searchField { performSearch(); return false }
        sendTapped(); return false
    }
}

// MARK: - UIAlertViewDelegate (delete confirmation)

extension ChatVC: UIAlertViewDelegate {
    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        let mid = pendingDeleteId
        pendingDeleteId = nil
        if buttonIndex == 1, let mid = mid { deleteMessage(mid) }   // 1 = "Delete"
    }
}

// MARK: - UITableViewDataSource / Delegate

extension ChatVC: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return tableView === resultsTable ? searchResults.count : messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "msg", for: indexPath) as! MessageCell

        // Results table: read-only cells (no grouping, no swipe/menu actions).
        if tableView === resultsTable {
            let msg = searchResults[indexPath.row]
            cell.configure(with: msg, grouped: false, separatorText: nil, replyPreview: nil)
            cell.isOwn = false
            cell.onEdit = nil; cell.onDelete = nil; cell.onReply = nil
            cell.onImageTap = { [weak self] img in
                let viewer = ImageViewerVC(image: img)
                self?.navigationController?.pushViewController(viewer, animated: true)
            }
            return cell
        }

        let msg = messages[indexPath.row]
        cell.configure(with: msg,
                       grouped: isGrouped(at: indexPath.row),
                       separatorText: daySeparatorText(at: indexPath.row),
                       replyPreview: replyDisplay(for: msg))
        cell.isOwn = (msg.authorId == StoatSocket.shared.currentUser?.id)
        let mid = msg.id, content = msg.content
        let replyAuthor  = msg.authorName
        let replyPreview = ChatVC.previewText(content, attachment: !msg.attachments.isEmpty)
        cell.onEdit   = { [weak self] in self?.beginEdit(messageId: mid, content: content) }
        cell.onDelete = { [weak self] in self?.confirmDelete(mid) }
        cell.onReply  = { [weak self] in self?.beginReply(messageId: mid, author: replyAuthor, preview: replyPreview) }
        cell.onImageTap = { [weak self] img in
            let viewer = ImageViewerVC(image: img)
            self?.navigationController?.pushViewController(viewer, animated: true)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if tableView === resultsTable {
            let msg = searchResults[indexPath.row]
            return ChatVC.rowHeight(for: msg, grouped: false, separator: false, hasReply: false)
        }
        let msg = messages[indexPath.row]
        return ChatVC.rowHeight(for: msg,
                                grouped: isGrouped(at: indexPath.row),
                                separator: daySeparatorText(at: indexPath.row) != nil,
                                hasReply: replyDisplay(for: msg) != nil)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === resultsTable { return }
        updateJumpButton()
    }

}

// MARK: - UIImagePickerControllerDelegate

extension ChatVC: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else { return }
        uploadImage(image)
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

// MARK: - MessageCell

private class MessageCell: UITableViewCell {

    private let authorLbl  = UILabel()
    private let timeLbl    = UILabel()
    private let contentLbl = UILabel()
    private let attachImg  = UIImageView()
    private let dateLbl    = UILabel()
    private let sepLine    = UIView()
    private let replyLbl   = UILabel()
    private var currentAttachId: String?
    var onImageTap: ((UIImage) -> Void)?
    var onEdit:     (() -> Void)?
    var onDelete:   (() -> Void)?
    var onReply:    (() -> Void)?
    var isOwn = false
    var detectedURLs: [NSURL] = []
    private var rawText = ""

    private static let imgCache = NSCache<NSString, UIImage>()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private static func formatTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 86400  { return timeFmt.string(from: date) }
        if diff < 172800 { return "Yesterday" }
        return dateFmt.string(from: date)
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        selectionStyle  = .none

        authorLbl.backgroundColor = .clear
        authorLbl.textColor = UIColor(red: 0.36, green: 0.56, blue: 0.90, alpha: 1)
        authorLbl.font = UIFont.boldSystemFont(ofSize: 13)
        contentView.addSubview(authorLbl)

        timeLbl.backgroundColor = .clear
        timeLbl.textColor = UIColor(white: 0.45, alpha: 1)
        timeLbl.font = UIFont.systemFont(ofSize: 11)
        contentView.addSubview(timeLbl)

        contentLbl.backgroundColor = .clear
        contentLbl.textColor = UIColor(white: 0.85, alpha: 1)
        contentLbl.font = UIFont.systemFont(ofSize: 14)
        contentLbl.numberOfLines = 0
        contentView.addSubview(contentLbl)
        let urlTap = UITapGestureRecognizer(target: self, action: #selector(urlTapped))
        urlTap.cancelsTouchesInView = false
        contentLbl.addGestureRecognizer(urlTap)

        attachImg.contentMode = .scaleAspectFill
        attachImg.layer.cornerRadius = 8
        attachImg.layer.masksToBounds = true
        attachImg.backgroundColor = UIColor(white: 0.18, alpha: 1)
        attachImg.isHidden = true
        attachImg.isUserInteractionEnabled = true
        contentView.addSubview(attachImg)
        let tap = UITapGestureRecognizer(target: self, action: #selector(imgTapped))
        attachImg.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        contentView.addGestureRecognizer(longPress)

        // Swipe left on a message = reply to it
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedToReply))
        swipe.direction = .left
        contentView.addGestureRecognizer(swipe)

        // Reply preview line shown above a message that is itself a reply
        replyLbl.backgroundColor = .clear
        replyLbl.textColor = UIColor(white: 0.5, alpha: 1)
        replyLbl.font = UIFont.systemFont(ofSize: 11)
        replyLbl.isHidden = true
        contentView.addSubview(replyLbl)

        // Date separator: a hairline with a centered date label that "breaks" the line
        sepLine.backgroundColor = UIColor(white: 1, alpha: 0.09)
        sepLine.isHidden = true
        contentView.addSubview(sepLine)

        dateLbl.backgroundColor = MessageCell.cellBg
        dateLbl.textColor = UIColor(white: 0.5, alpha: 1)
        dateLbl.font = UIFont.boldSystemFont(ofSize: 11)
        dateLbl.textAlignment = .center
        dateLbl.isHidden = true
        contentView.addSubview(dateLbl)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { return true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:))     { return !rawText.isEmpty }
        if action == #selector(editMsg(_:))  { return isOwn && !rawText.isEmpty }
        if action == #selector(deleteMsg(_:)) { return isOwn }
        return false
    }

    override func copy(_ sender: Any?) {
        UIPasteboard.general.string = rawText
    }

    @objc private func editMsg(_ sender: Any?)   { onEdit?() }
    @objc private func deleteMsg(_ sender: Any?) { onDelete?() }

    @objc private func longPressed(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        guard !rawText.isEmpty || isOwn else { return }   // nothing actionable
        becomeFirstResponder()
        var items: [UIMenuItem] = []
        if isOwn && !rawText.isEmpty {
            items.append(UIMenuItem(title: "Edit", action: #selector(editMsg(_:))))
        }
        if isOwn {
            items.append(UIMenuItem(title: "Delete", action: #selector(deleteMsg(_:))))
        }
        let menu = UIMenuController.shared
        menu.menuItems = items.isEmpty ? nil : items
        let rect = rawText.isEmpty ? attachImg.frame : contentLbl.frame
        menu.setTargetRect(rect, in: contentView)
        menu.setMenuVisible(true, animated: true)
    }

    @objc private func swipedToReply() { onReply?() }

    @objc private func imgTapped() { if let img = attachImg.image { onImageTap?(img) } }

    @objc private func urlTapped() {
        guard let url = detectedURLs.first else { return }
        UIApplication.shared.openURL(url as URL)
    }

    func configure(with msg: StoatMessage, grouped: Bool, separatorText: String?, replyPreview: String?) {
        rawText = msg.content
        let sw = UIScreen.main.bounds.width
        let w  = sw - 24
        let sepH: CGFloat = separatorText != nil ? 30 : 0

        // Date separator
        if let sepText = separatorText {
            dateLbl.text = sepText
            dateLbl.sizeToFit()
            let dw = dateLbl.frame.width + 16
            dateLbl.frame = CGRect(x: (sw - dw) / 2, y: 5, width: dw, height: 18)
            sepLine.frame = CGRect(x: 16, y: 14, width: sw - 32, height: 1)
            dateLbl.isHidden = false
            sepLine.isHidden = false
        } else {
            dateLbl.isHidden = true
            sepLine.isHidden = true
        }

        // Reply preview (shown above the message when it replies to another)
        let replyH: CGFloat = replyPreview != nil ? 18 : 0
        if let rp = replyPreview {
            replyLbl.text  = rp
            replyLbl.frame = CGRect(x: 12, y: sepH + 2, width: w, height: 16)
            replyLbl.isHidden = false
        } else {
            replyLbl.isHidden = true
        }

        // Author + time only shown on the first message of a group
        if grouped {
            authorLbl.isHidden = true
            timeLbl.isHidden   = true
        } else {
            authorLbl.isHidden = false
            timeLbl.isHidden   = false
            authorLbl.text  = msg.authorName
            authorLbl.frame = CGRect(x: 12, y: sepH + replyH + 8, width: w - 52, height: 16)
            timeLbl.text  = msg.timestamp.map { MessageCell.formatTime($0) } ?? ""
            timeLbl.frame = CGRect(x: sw - 52, y: sepH + replyH + 10, width: 48, height: 12)
        }

        let (attrStr, urls) = MessageCell.format(msg.content)
        let display = NSMutableAttributedString(attributedString: attrStr)
        if msg.edited {
            display.append(NSAttributedString(string: "  (edited)", attributes: [
                NSAttributedString.Key.foregroundColor: UIColor(white: 0.4, alpha: 1),
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 11)]))
        }
        contentLbl.attributedText = display
        detectedURLs = urls
        contentLbl.isUserInteractionEnabled = !urls.isEmpty
        let textH = (msg.content.isEmpty && !msg.edited) ? 0 :
            ceil(contentLbl.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height)
        contentLbl.frame = CGRect(x: 12, y: sepH + replyH + (grouped ? 6 : 28), width: w, height: textH)

        // Reset attachment
        currentAttachId = nil
        attachImg.isHidden = true
        attachImg.image = nil
        onImageTap = nil

        if let att = msg.attachments.first, att.isImage {
            currentAttachId = att.id
            let thumbH: CGFloat = att.width > 0
                ? min(220, CGFloat(att.height) * w / CGFloat(att.width)) : 160
            let imgY = contentLbl.frame.maxY + (msg.content.isEmpty ? 4 : 8)
            attachImg.frame = CGRect(x: 12, y: imgY, width: w, height: thumbH)
            attachImg.isHidden = false
            if let cached = MessageCell.imgCache.object(forKey: att.id as NSString) {
                attachImg.image = cached
            } else {
                loadImage(att)
            }
        }
    }

    private static let cellBg = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)

    private static func format(_ text: String) -> (NSAttributedString, [NSURL]) {
        let baseFont  = UIFont.systemFont(ofSize: 14)
        let boldFont  = UIFont.boldSystemFont(ofSize: 14)
        let italFont  = UIFont.italicSystemFont(ofSize: 14)
        let codeFont  = UIFont(name: "Courier", size: 13) ?? baseFont
        let textColor = UIColor(white: 0.85, alpha: 1)
        let (resolved, mentionRanges) = resolveMentions(text)
        let result = NSMutableAttributedString(string: resolved, attributes: [
            NSAttributedString.Key.foregroundColor: textColor,
            NSAttributedString.Key.font: baseFont,
        ])
        func applyMarkdown(_ pattern: String, markerLen: Int, font: UIFont) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let ns = result.string as NSString
            let ms = re.matches(in: result.string, options: [],
                                range: NSRange(location: 0, length: ns.length))
            for m in ms.reversed() {
                let mr = m.range
                guard mr.length > markerLen * 2 else { continue }
                result.addAttribute(.foregroundColor, value: cellBg,
                    range: NSRange(location: mr.location, length: markerLen))
                result.addAttribute(.font, value: font,
                    range: NSRange(location: mr.location + markerLen,
                                  length: mr.length - markerLen * 2))
                result.addAttribute(.foregroundColor, value: cellBg,
                    range: NSRange(location: mr.location + mr.length - markerLen,
                                  length: markerLen))
            }
        }
        applyMarkdown("\\*\\*(.+?)\\*\\*", markerLen: 2, font: boldFont)
        applyMarkdown("(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)", markerLen: 1, font: italFont)
        applyMarkdown("`([^`]+)`", markerLen: 1, font: codeFont)
        var urls: [NSURL] = []
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns2 = result.string as NSString
            let ms2 = det.matches(in: result.string, options: [],
                                  range: NSRange(location: 0, length: ns2.length))
            let linkColor = UIColor(red: 0.36, green: 0.56, blue: 0.90, alpha: 1)
            for m in ms2 {
                result.addAttribute(.foregroundColor, value: linkColor, range: m.range)
                if let u = m.url { urls.append(u as NSURL) }
            }
        }
        // Highlight resolved @mentions (applied last so it wins over link coloring)
        let mentionColor = UIColor(red: 0.36, green: 0.56, blue: 0.90, alpha: 1)
        let len = (result.string as NSString).length
        for r in mentionRanges where r.location + r.length <= len {
            result.addAttribute(.foregroundColor, value: mentionColor, range: r)
            result.addAttribute(.font, value: boldFont, range: r)
        }
        return (result, urls)
    }

    // Resolve <@userId> tokens to "@username", returning the rewritten string
    // and the NSRanges (UTF-16) of each inserted @mention for highlighting.
    fileprivate static func resolveMentions(_ text: String) -> (String, [NSRange]) {
        guard text.range(of: "<@") != nil,
              let re = try? NSRegularExpression(pattern: "<@([0-9A-Za-z]+)>", options: []) else {
            return (text, [])
        }
        let ns = text as NSString
        let matches = re.matches(in: text, options: [],
                                 range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, []) }
        let out = NSMutableString()
        var ranges: [NSRange] = []
        var last = 0
        for m in matches {
            let full = m.range
            out.append(ns.substring(with: NSRange(location: last, length: full.location - last)))
            let uid   = ns.substring(with: m.range(at: 1))
            let uname = StoatSocket.shared.allUsers[uid]?.username ?? "unknown"
            let token = "@" + uname
            ranges.append(NSRange(location: out.length, length: (token as NSString).length))
            out.append(token)
            last = full.location + full.length
        }
        out.append(ns.substring(with: NSRange(location: last, length: ns.length - last)))
        return (out as String, ranges)
    }

    private func loadImage(_ att: StoatAttachment) {
        let aid = att.id
        var hdrs: [String: String] = [:]
        if let tok = APIClient.sessionToken { hdrs["x-session-token"] = tok }
        StoatDebug.log("loadImage: url=\(att.url)")
        HTTPClient.request(att.url, headers: hdrs) { [weak self] data, status, err in
            StoatDebug.log("loadImage: status=\(status) dataLen=\(data?.count ?? -1)")
            guard let data = data, let img = UIImage(data: data) else {
                StoatDebug.log("loadImage: bad data aid=\(aid) status=\(status)")
                return
            }
            // Cache before cell-reuse check so scrolling back shows the image immediately
            MessageCell.imgCache.setObject(img, forKey: aid as NSString)
            guard let self = self, self.currentAttachId == aid else { return }
            self.attachImg.image = img
        }
    }
}

// MARK: - ImageViewerVC (full-screen with pinch zoom)

private class ImageViewerVC: UIViewController, UIScrollViewDelegate {

    private let scrollView = UIScrollView()
    private let imageView  = UIImageView()
    private let img: UIImage

    init(image: UIImage) { img = image; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "Image"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .plain, target: self, action: #selector(saveImage))

        scrollView.frame = view.bounds
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator   = false
        view.addSubview(scrollView)

        imageView.image = img
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        scrollView.addSubview(imageView)
    }

    @objc private func saveImage() {
        UIImageWriteToSavedPhotosAlbum(img, self, #selector(saved(_:error:context:)), nil)
    }

    @objc private func saved(_ image: UIImage, error: NSError?, context: UnsafeRawPointer?) {
        if error == nil {
            title = "Saved!"
            let t = Timer(timeInterval: 1.5, target: self,
                          selector: #selector(resetTitle), userInfo: nil, repeats: false)
            RunLoop.main.add(t, forMode: .common)
        } else {
            UIAlertView(title: "Could not save",
                        message: error?.localizedDescription ?? "Unknown error",
                        delegate: nil, cancelButtonTitle: "OK").show()
        }
    }

    @objc private func resetTitle() { title = "Image" }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { return imageView }
}
