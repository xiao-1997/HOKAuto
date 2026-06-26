import SwiftUI
import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 配置百度 PP-OCRv5 云端 OCR（凭据在 Secrets.swift，不上传 GitHub）
        PaddleOCRClient.configure(
            apiKey: Secrets.baiduAPIKey,
            secretKey: Secrets.baiduSecretKey
        )

        // 启动 Lua 视觉桥接（Vision OCR + PaddleOCR + YOLO + DeepSeek）
        LuaVisionBridge.shared.usePaddleOCR = true
        LuaVisionBridge.shared.start()

        let contentView = ContentView()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: contentView)
        self.window = window
        window.makeKeyAndVisible()
        return true
    }
}
