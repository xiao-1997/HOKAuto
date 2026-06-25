import Foundation

/// 操作录制与回放
struct MacroRecorder {
    struct Step: Codable {
        let x: Float
        let y: Float
        let source: String   // fixed/template/ocr/ai
        let label: String     // 按钮名称
        let timestamp: TimeInterval
    }

    static let saveDir = "/var/mobile/Documents"
    private static var current: [Step] = []

    // MARK: - 录制

    static func record(x: Float, y: Float, source: String, label: String = "") {
        current.append(Step(x: x, y: y, source: source, label: label.isEmpty ? source : label,
            timestamp: Date().timeIntervalSince1970))
    }

    static func startSession() { current = [] }
    static func stopSession() { Logger.log("录制完成: \(current.count)步") }

    // MARK: - 保存/加载

    static func save(_ name: String) -> Bool {
        let path = "\(saveDir)/macro_\(name).json"
        guard let data = try? JSONEncoder().encode(current) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            Logger.log("宏已保存: \(name) (\(current.count)步)")
            return true
        } catch {
            Logger.log("保存失败: \(error)")
            return false
        }
    }

    static func load(_ name: String) -> [Step]? {
        let path = "\(saveDir)/macro_\(name).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let steps = try? JSONDecoder().decode([Step].self, from: data) else { return nil }
        Logger.log("宏已加载: \(name) (\(steps.count)步)")
        return steps
    }

    static func listSaved() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: saveDir) else { return [] }
        return files.filter { $0.hasPrefix("macro_") && $0.hasSuffix(".json") }
            .map { $0.replacingOccurrences(of: "macro_", with: "").replacingOccurrences(of: ".json", with: "") }
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(atPath: "\(saveDir)/macro_\(name).json")
    }

    // MARK: - 回放

    static func replay(steps: [Step], engine: AutomationEngine) {
        Logger.log("开始回放 \(steps.count)步")
        DispatchQueue.global().async {
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.async {
                    engine.status = "回放 \(i+1)/\(steps.count)"
                }
                ve_click(step.x, step.y)
                usleep(UInt32(150000 * (1 + step.label.count))) // 按名称长度调整间隔
            }
            DispatchQueue.main.async {
                Logger.log("回放完成")
            }
        }
    }
}
