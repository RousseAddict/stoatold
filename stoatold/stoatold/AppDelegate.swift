import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        let splash = SplashVC()
        let nav = UINavigationController(rootViewController: splash)
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(red: 0.55, green: 0.27, blue: 0.87, alpha: 1)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        return true
    }
}
