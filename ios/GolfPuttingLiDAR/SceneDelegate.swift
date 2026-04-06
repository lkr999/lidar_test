import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        
        let window = UIWindow(windowScene: windowScene)
        
        if #available(iOS 14.0, *) {
            window.rootViewController = MainViewController()
        } else {
            // iOS 14 미만은 LiDAR 미지원
            let vc = UIViewController()
            vc.view.backgroundColor = UIColor(red: 0.05, green: 0.1, blue: 0.16, alpha: 1)
            
            let label = UILabel()
            label.text = "이 앱은 iOS 14.0 이상 + LiDAR 지원 기기가 필요합니다."
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            vc.view.addSubview(label)
            
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 32),
                label.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -32),
            ])
            
            window.rootViewController = vc
        }
        
        self.window = window
        window.makeKeyAndVisible()
    }
}
