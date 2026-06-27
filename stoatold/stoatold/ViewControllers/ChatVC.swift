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
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "< Channels", style: .plain, target: self, action: #selector(goBack))
        buildUI()
        fetchMessages()
        StoatSocket.shared.onEvent = { [weak self] json in self?.handleEvent(json) }
    }

    @objc private func goBack() { navigationController?.popViewController(animated: true) }

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
        let evType = json["type"] as? String ?? "(none)"
        let evCh   = json["channel"] as? String ?? "?"
        StoatDebug.log("event: type=\(evType) ch=\(evCh)")
        guard let type = json["type"] as? String, type == "Message",
              let chId = json["channel"] as? String, chId == channel.id else { return }
        guard let msg = StoatMessage.from(dict: json) else {
            StoatDebug.log("event: Message parse failed keys=\(Array(json.keys))")
            return
        }
        guard !messages.contains(where: { $0.id == msg.id }) else { return }
        messages.append(msg)
        emptyLabel.isHidden = true
        tableView.insertRows(at: [IndexPath(row: messages.count - 1, section: 0)], with: .none)
        scrollToBottom()
        if msg.displayName == nil && StoatSocket.shared.allUsers[msg.authorId] == nil {
            APIClient.get("/users/\(msg.authorId)") { [weak self] json, _ in
                if let dict = json as? [String: Any], let u = StoatUser.from(dict: dict) {
                    StoatSocket.shared.cacheUser(u); self?.tableView.reloadData()
                }
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
        guard !text.isEmpty || pendingAttachId != nil else { return }
        textField.text = ""

        var payload: [String: Any] = ["content": text, "replies": []]
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

    // MARK: - Row height

    private static let sizer: UILabel = {
        let l = UILabel(); l.font = UIFont.systemFont(ofSize: 14); l.numberOfLines = 0; return l
    }()

    fileprivate static func rowHeight(for msg: StoatMessage) -> CGFloat {
        let w = UIScreen.main.bounds.width - 24
        sizer.text = msg.content.isEmpty ? " " : msg.content
        let textH = ceil(sizer.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height)
        var h = max(56, textH + 42)
        if let att = msg.attachments.first, att.isImage {
            if att.width > 0 {
                h += min(220, CGFloat(att.height) * w / CGFloat(att.width)) + 8
            } else {
                h += 180
            }
        }
        return h
    }
}

// MARK: - UITextFieldDelegate

extension ChatVC: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { sendTapped(); return false }
}

// MARK: - UITableViewDataSource / Delegate

extension ChatVC: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "msg", for: indexPath) as! MessageCell
        let msg = messages[indexPath.row]
        cell.configure(with: msg)
        cell.onImageTap = { [weak self] img in
            let viewer = ImageViewerVC(image: img)
            self?.navigationController?.pushViewController(viewer, animated: true)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return ChatVC.rowHeight(for: messages[indexPath.row])
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return messages[indexPath.row].authorId == StoatSocket.shared.currentUser?.id
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete,
              let token = APIClient.sessionToken else { return }
        let msg = messages[indexPath.row]
        HTTPClient.request("\(APIClient.baseURL)/channels/\(channel.id)/messages/\(msg.id)",
                           method: "DELETE",
                           headers: ["x-session-token": token]) { [weak self] _, status, _ in
            guard let self = self else { return }
            if status == 204 || status == 200 {
                self.messages.remove(at: indexPath.row)
                self.tableView.deleteRows(at: [indexPath], with: .fade)
            }
        }
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
    private var currentAttachId: String?
    var onImageTap: ((UIImage) -> Void)?
    var detectedURLs: [NSURL] = []

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
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func imgTapped() { if let img = attachImg.image { onImageTap?(img) } }

    @objc private func urlTapped() {
        guard let url = detectedURLs.first else { return }
        UIApplication.shared.openURL(url as URL)
    }

    func configure(with msg: StoatMessage) {
        let w = UIScreen.main.bounds.width - 24
        authorLbl.text  = msg.authorName
        authorLbl.frame = CGRect(x: 12, y: 8, width: w - 52, height: 16)

        timeLbl.text  = msg.timestamp.map { MessageCell.formatTime($0) } ?? ""
        timeLbl.frame = CGRect(x: UIScreen.main.bounds.width - 52, y: 10, width: 48, height: 12)

        let (attrStr, urls) = MessageCell.format(msg.content)
        contentLbl.attributedText = attrStr
        detectedURLs = urls
        contentLbl.isUserInteractionEnabled = !urls.isEmpty
        let textH = msg.content.isEmpty ? 0 :
            ceil(contentLbl.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height)
        contentLbl.frame = CGRect(x: 12, y: 28, width: w, height: textH)

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
        let result = NSMutableAttributedString(string: text, attributes: [
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
        return (result, urls)
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
