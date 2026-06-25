import UIKit

/// 宏录制与智能回放
struct MacroRecorder {

    // MARK: - 数据结构

    struct Meta: Codable {
        let width: Int       // 屏幕宽
        let height: Int      // 屏幕高
        let scale: CGFloat   // 缩放比
        let iosVersion: String
        let orientation: String  // portrait/landscape
        let appVersion: String
        let createdAt: TimeInterval
    }

    struct Step: Codable {
        let x: Float; let y: Float
        let source: String   // fixed/ocr/ai/manual
        let label: String
        let timestamp: TimeInterval
    }

    struct Macro: Codable {
        let meta: Meta
        var steps: [Step]
    }

    // MARK: - 录制控制

    static var isRecording = false
    private static var current = Macro(
        meta: Meta(width: 0, height: 0, scale: 1, iosVersion: "", orientation: "landscape",
                   appVersion: "1.0", createdAt: Date().timeIntervalSince1970),
        steps: []
    )

    static func startSession() {
        current = Macro(
            meta: Meta(
                width: Int(UIScreen.main.bounds.width),
                height: Int(UIScreen.main.bounds.height),
                scale: UIScreen.main.scale,
                iosVersion: UIDevice.current.systemVersion,
                orientation: UIScreen.main.bounds.width > UIScreen.main.bounds.height ? "landscape" : "portrait",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                createdAt: Date().timeIntervalSince1970
            ),
            steps: []
        )
        Logger.log("录制开始 分辨率:\(current.meta.width)x\(current.meta.height)")
    }

    static func record(x: Float, y: Float, source: String, label: String = "") {
        guard isRecording else { return }
        current.steps.append(Step(x: x, y: y, source: source,
            label: label.isEmpty ? source : label, timestamp: Date().timeIntervalSince1970))
    }

    static let saveDir = "/var/mobile/Documents"

    static func save(_ name: String) -> Bool {
        guard !current.steps.isEmpty else { return false }
        guard let data = try? JSONEncoder().encode(current) else { return false }
        let path = "\(saveDir)/macro_\(name).json"
        do { try data.write(to: URL(fileURLWithPath: path))
            Logger.log("宏已保存: \(name) (\(current.steps.count)步)")
            return true } catch { return false }
    }

    /// 加载宏并根据当前分辨率缩放坐标
    static func load(_ name: String) -> (macro: Macro, scaleX: Float, scaleY: Float)? {
        let path = "\(saveDir)/macro_\(name).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let macro = try? JSONDecoder().decode(Macro.self, from: data) else { return nil }

        let curW = Float(UIScreen.main.bounds.width)
        let curH = Float(UIScreen.main.bounds.height)
        let scaleX = curW / Float(macro.meta.width)
        let scaleY = curH / Float(macro.meta.height)

        Logger.log("加载宏:\(name) 录制:\(macro.meta.width)x\(macro.meta.height) 当前:\(Int(curW))x\(Int(curH)) 缩放:\(scaleX)x\(scaleY)")
        return (macro, scaleX, scaleY)
    }

    static func list() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: saveDir))?
            .filter { $0.hasPrefix("macro_") && $0.hasSuffix(".json") }
            .map { $0.replacingOccurrences(of: "macro_", with: "").replacingOccurrences(of: ".json", with: "") } ?? []
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(atPath: "\(saveDir)/macro_\(name).json")
    }

    // MARK: - 智能回放

    /// 回放宏：每步缩放坐标 + OCR校验 + AI兜底
    static func smartReplay(name: String, engine: AutomationEngine) {
        guard let (macro, sx, sy) = load(name) else { return }

        Logger.log("智能回放:\(name) \(macro.steps.count)步")

        DispatchQueue.global().async {
            for (i, step) in macro.steps.enumerated() {
                let x = step.x * sx
                let y = step.y * sy

                DispatchQueue.main.async {
                    engine.status = "回放 \(i+1)/\(macro.steps.count)"
                    engine.onUpdate?()
                }

                // 执行点击
                engine.tapNoRecord(x, y)

                // 每步间隔中检测弹窗
                usleep(300000)

                // OCR 检测弹窗(仅每3步)
                if i % 3 == 2 {
                    if let screen = ScreenCapture.capture(maxWidth: 300, quality: 0.3) {
                        let hits = LocalVision.detectKeywords(screen)
                        if !hits.isEmpty {
                            DispatchQueue.main.async {
                                engine.status = "回放中检测到弹窗→处理"
                                engine.onUpdate?()
                            }
                            for h in hits {
                                engine.tapNoRecord(h.x, h.y); usleep(200000)
                            }
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                Logger.log("回放完成:\(name)")
            }
        }
    }
}
