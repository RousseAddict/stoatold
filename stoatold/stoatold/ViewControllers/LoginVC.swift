import UIKit

class LoginVC: UIViewController {

    private let w = UIScreen.main.bounds.width

    private let logoView         = UIImageView()
    private let emailField      = UITextField()
    private let passField       = UITextField()
    private let serverField     = UITextField()
    private let toggleServerBtn = UIButton(type: .custom)
    private let loginBtn        = UIButton(type: .custom)
    private let errorLabel      = UILabel()
    private let spinner         = UIActivityIndicatorView(style: .white)

    private var showingServer  = false
    private var activeField: UITextField?
    private var viewOriginY: CGFloat = 0

    private let accent    = UIColor(red: 0.55, green: 0.27, blue: 0.87, alpha: 1)
    private let fieldBg   = UIColor(red: 0.15, green: 0.15, blue: 0.2,  alpha: 1)
    private let pad: CGFloat = 24
    private let fh:  CGFloat = 44

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        navigationController?.navigationBar.isHidden = true
        buildUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewOriginY = view.frame.origin.y
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDidShow(_:)),
            name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.navigationBar.isHidden = false
        NotificationCenter.default.removeObserver(self,
            name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self,
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - Keyboard avoidance

    @objc private func keyboardDidShow(_ note: Notification) {
        guard let info = note.userInfo,
              let kbFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }

        // Bottom of the element we need visible = bottom of login button
        let targetBottom = loginBtn.frame.maxY + 10
        let visibleHeight = UIScreen.main.bounds.height - kbFrame.height
        let shift = targetBottom - visibleHeight

        if shift > 0 {
            var f = view.frame
            f.origin.y = viewOriginY - shift
            UIView.animate(withDuration: 0.25) { self.view.frame = f }
        }
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        UIView.animate(withDuration: 0.25) {
            var f = self.view.frame
            f.origin.y = self.viewOriginY
            self.view.frame = f
        }
    }

    // MARK: - UI

    private func buildUI() {
        var y: CGFloat = 40

        // Logo icon — loose bundle file works on iOS 6+; asset catalog on iOS 7+
        let logoImg = UIImage(named: "stoatold_logo")
            ?? UIImage(named: "LogoImage")
        logoView.image = logoImg
        logoView.alpha = logoImg != nil ? 1.0 : 0.0
        logoView.contentMode = .scaleAspectFit
        logoView.frame = CGRect(x: pad, y: y, width: w - pad*2, height: 130)
        view.addSubview(logoView)
        y += 138

        // Subtitle
        let sub = UILabel()
        sub.backgroundColor = .clear
        sub.text = "stoat.chat client"
        sub.textColor = UIColor(white: 0.5, alpha: 1)
        sub.font = UIFont.systemFont(ofSize: 14)
        sub.textAlignment = .center
        sub.frame = CGRect(x: pad, y: y, width: w - pad*2, height: 20)
        view.addSubview(sub)
        y += 50

        // Email field
        emailField.frame = CGRect(x: pad, y: y, width: w - pad*2, height: fh)
        styleField(emailField, placeholder: "Email")
        emailField.keyboardType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.autocorrectionType = .no
        emailField.returnKeyType = .next
        emailField.delegate = self
        view.addSubview(emailField)
        y += fh + 12

        // Password field
        passField.frame = CGRect(x: pad, y: y, width: w - pad*2, height: fh)
        styleField(passField, placeholder: "Password")
        passField.isSecureTextEntry = true
        passField.returnKeyType = .done
        passField.delegate = self
        view.addSubview(passField)
        y += fh + 16

        // Custom server toggle
        toggleServerBtn.frame = CGRect(x: pad, y: y, width: w - pad*2, height: 28)
        toggleServerBtn.setTitle("+ Custom server", for: .normal)
        toggleServerBtn.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .normal)
        toggleServerBtn.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        toggleServerBtn.contentHorizontalAlignment = .left
        toggleServerBtn.addTarget(self, action: #selector(toggleServer), for: .touchUpInside)
        view.addSubview(toggleServerBtn)
        y += 28 + 6

        // Custom server URL field (hidden by default)
        serverField.frame = CGRect(x: pad, y: y, width: w - pad*2, height: fh)
        styleField(serverField, placeholder: "https://stoat.chat/api")
        serverField.text = APIClient.baseURL == APIClient.defaultBaseURL ? "" : APIClient.baseURL
        serverField.keyboardType = .URL
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no
        serverField.returnKeyType = .done
        serverField.delegate = self
        serverField.isHidden = true
        view.addSubview(serverField)

        // Login button — positioned dynamically
        loginBtn.backgroundColor = accent
        loginBtn.setTitleColor(.white, for: .normal)
        loginBtn.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .disabled)
        loginBtn.setTitle("Log in", for: .normal)
        loginBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        loginBtn.layer.cornerRadius = 6
        loginBtn.layer.masksToBounds = true
        loginBtn.addTarget(self, action: #selector(doLogin), for: .touchUpInside)
        view.addSubview(loginBtn)

        // Spinner inside login button
        spinner.hidesWhenStopped = true
        loginBtn.addSubview(spinner)

        // Error label
        errorLabel.backgroundColor = .clear
        errorLabel.textColor = UIColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1)
        errorLabel.font = UIFont.systemFont(ofSize: 13)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        view.addSubview(errorLabel)

        repositionLoginBtn()
    }

    private func styleField(_ field: UITextField, placeholder: String) {
        field.backgroundColor = fieldBg
        field.textColor = .white
        field.borderStyle = .none
        field.contentVerticalAlignment = .center
        field.layer.cornerRadius = 6
        field.layer.masksToBounds = true
        // Padding view — interaction disabled so taps always reach the field
        let pad = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: Int(fh)))
        pad.isUserInteractionEnabled = false
        field.leftView = pad
        field.leftViewMode = .always
        // Right padding
        let rpad = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: Int(fh)))
        rpad.isUserInteractionEnabled = false
        field.rightView = rpad
        field.rightViewMode = .always
        let attrs = [NSAttributedString.Key.foregroundColor: UIColor(white: 0.45, alpha: 1)]
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: attrs)
    }

    private func repositionLoginBtn() {
        let serverFieldY = toggleServerBtn.frame.maxY + 6
        let loginY: CGFloat
        if showingServer {
            loginY = serverFieldY + fh + 14
        } else {
            loginY = serverFieldY + 4
        }
        loginBtn.frame = CGRect(x: pad, y: loginY, width: w - pad*2, height: fh)
        spinner.frame = CGRect(x: loginBtn.bounds.width - 44, y: 0, width: 44, height: fh)
        errorLabel.frame = CGRect(x: pad, y: loginY + fh + 10, width: w - pad*2, height: 60)
    }

    // MARK: - Actions

    @objc private func toggleServer() {
        showingServer = !showingServer
        serverField.isHidden = !showingServer
        let label = showingServer ? "- Custom server" : "+ Custom server"
        toggleServerBtn.setTitle(label, for: .normal)
        repositionLoginBtn()
        if showingServer { serverField.becomeFirstResponder() }
    }

    @objc private func doLogin() {
        guard let email = emailField.text, !email.isEmpty,
              let pass  = passField.text,  !pass.isEmpty else {
            showError("Please enter email and password")
            return
        }

        // Apply custom server URL if visible and filled
        if showingServer, var url = serverField.text, !url.isEmpty {
            if url.hasSuffix("/") { url = String(url.dropLast()) }
            APIClient.baseURL = url
        }

        errorLabel.text = ""
        // Remove keyboard observers before dismissing to avoid animation/transition race
        NotificationCenter.default.removeObserver(self,
            name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self,
            name: UIResponder.keyboardWillHideNotification, object: nil)
        // Restore view position before transition
        var restoreFrame = view.frame
        restoreFrame.origin.y = viewOriginY
        view.frame = restoreFrame
        view.endEditing(true)
        setLoading(true)

        APIClient.login(email: email, password: pass) { [weak self] token, err in
            guard let self = self else { return }
            self.setLoading(false)
            if let token = token {
                APIClient.sessionToken = token
                self.navigationController?.navigationBar.isHidden = false
                self.navigationController?.setViewControllers([ServerListVC()], animated: true)
            } else {
                self.showError(err ?? "Login failed")
            }
        }
    }

    private func setLoading(_ on: Bool) {
        loginBtn.isEnabled = !on
        loginBtn.setTitle(on ? "" : "Log in", for: .normal)
        on ? spinner.startAnimating() : spinner.stopAnimating()
    }

    private func showError(_ msg: String) {
        errorLabel.text = msg
    }
}

// MARK: - UITextFieldDelegate

extension LoginVC: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === emailField {
            passField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
            if textField === passField { doLogin() }
        }
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        activeField = textField
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        activeField = nil
    }
}
