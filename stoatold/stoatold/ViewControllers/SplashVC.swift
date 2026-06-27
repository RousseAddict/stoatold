import UIKit

// Shown at launch while we validate any saved session token, then routes to
// LoginVC or ServerListVC.
//
// iOS 6/7 fix: do NOT mutate the navigation stack synchronously inside
// viewDidLoad — replacing rootViewController's VCs while the nav controller is
// still mid-load crashes. Defer the session check + routing to viewDidAppear
// (and the validateSession callback hops back via DispatchQueue.main.async),
// so each navigation mutation happens in its own run-loop turn.
class SplashVC: UIViewController {

    private let spinner = UIActivityIndicatorView(style: .white)
    private var started = false
    private var didRoute = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        navigationController?.navigationBar.isHidden = true

        spinner.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        spinner.center = CGPoint(x: UIScreen.main.bounds.width / 2,
                                 y: UIScreen.main.bounds.height / 2)
        view.addSubview(spinner)
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true

        if APIClient.isLoggedIn {
            APIClient.validateSession { [weak self] valid in
                if !valid { APIClient.sessionToken = nil }
                DispatchQueue.main.async { self?.route() }
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.route() }
        }
    }

    private func route() {
        guard !didRoute else { return }
        didRoute = true
        navigationController?.navigationBar.isHidden = false
        let logged = APIClient.isLoggedIn
        let dest: UIViewController = logged ? ServerListVC() : LoginVC()
        navigationController?.setViewControllers([dest], animated: false)
    }
}
