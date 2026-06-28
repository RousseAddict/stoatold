import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UIAlertViewDelegate {
    var window: UIWindow?
    private var pendingTrace: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Capture any backtrace saved by the previous run's crash, THEN install
        // (install truncates the log for this run).
        pendingTrace = CrashTraceRead()
        CrashTraceInstall()

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        let splash = SplashVC()
        let nav = UINavigationController(rootViewController: splash)
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(red: 0.55, green: 0.27, blue: 0.87, alpha: 1)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()

        if let trace = pendingTrace, !trace.isEmpty {
            let a = UIAlertView(title: "CRASH TRACE (last run)",
                                message: trace,
                                delegate: self,
                                cancelButtonTitle: "OK")
            a.addButton(withTitle: "Copy")
            DispatchQueue.main.async { a.show() }
        }
        return true
    }

    // Lock the whole app to portrait (authoritative on iOS 6/7 — the app-level plist
    // ~iphone key alone is not always honored under a UINavigationController).
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        if buttonIndex == 1, let t = pendingTrace {
            UIPasteboard.general.string = t
        }
    }
}
