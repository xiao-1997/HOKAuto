import Foundation
import SwiftUI
import UIKit

@MainActor
class AutomationEngine: ObservableObject {
    @Published var status = "就绪"
    @Published var logs = ""
    @Published var isRunning = false

    func run() {
        guard !isRunning else { return }
        isRunning = true
        status = "启动中..."
        logs = ""

        Task {
            do {
                // Step 1: 连接 WDA
                log("检查 WDA 连接...")
                let wdaOk = try await WDAHelper.checkConnection()
                log(wdaOk ? "WDA 已连接" : "WDA 未连接")

                // Step 2: 启动王者荣耀
                status = "正在启动王者荣耀"
                log("启动 王者荣耀...")

                if wdaOk {
                    try await WDAHelper.launchApp(bundleId: "com.tencent.smoba")
                } else {
                    log("通过 URL Scheme 启动")
                    WDAHelper.openViaScheme()
                }
                log("王者荣耀已启动")

                // Step 3: 等待 10 秒
                for i in 1...10 {
                    status = "等待中... \(11 - i)秒"
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }

                // Step 4: 关闭
                status = "正在关闭"
                log("关闭...")
                if wdaOk {
                    try await WDAHelper.pressHome()
                }
                log("已完成")
                status = "完成"

            } catch {
                log("错误: \(error.localizedDescription)")
                status = "失败"
            }

            isRunning = false
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}

// MARK: - WDA HTTP Client

struct WDAHelper {
    static let baseURL = "http://localhost:8100"

    static func checkConnection() async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/status") else { return false }
        let (_, resp) = try await URLSession.shared.data(from: url)
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    static func launchApp(bundleId: String) async throws {
        let url = URL(string: "\(baseURL)/session")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["capabilities": ["bundleId": bundleId]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    static func pressHome() async throws {
        guard let url = URL(string: "\(baseURL)/homescreen") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: req)
    }

    /// 通过 URL Scheme 启动（备用方案）
    static func openViaScheme() {
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url)
        }
    }
}
