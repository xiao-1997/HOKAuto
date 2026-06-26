import Foundation

/// 坐标缓存条目：记录每个UI元素的屏幕位置及命中统计
struct CoordEntry: Codable {
    let label: String           // 识别名: "关闭弹窗", "充值按钮", "475点券"
    let x, y: Float             // 屏幕坐标 (1242x2208 逻辑分辨率)
    let screenW, screenH: Float // 记录时的屏幕分辨率，用于跨设备坐标缩放
    var hitCount: Int           // 命中次数（越高越可信）
    var lastHit: Date           // 最后命中时间
    let source: String          // "manual"(用户预设) / "ocr" / "yolo"

    /// 跨设备坐标缩放：将缓存坐标映射到当前屏幕分辨率
    func scaledX(to currentW: Float) -> Float { x * currentW / screenW }
    func scaledY(to currentH: Float) -> Float { y * currentH / screenH }
}

/// 坐标记忆库：持久化存储所有UI元素坐标，越用越快
class CoordCache {
    static let shared = CoordCache()

    private var entries: [String: CoordEntry] = [:]
    private let cacheFile = "/var/mobile/Documents/HOKAuto/coord_cache.json"
    private let queue = DispatchQueue(label: "coord.cache", attributes: .concurrent)

    // MARK: - Init

    init() { load() }

    // MARK: - 查询

    /// 查缓存（线程安全）
    func get(_ label: String) -> CoordEntry? {
        queue.sync { entries[label] }
    }

    /// 查询所有包含指定关键词的缓存（用于弹窗批量命中）
    func query(containsAny keywords: [String]) -> [CoordEntry] {
        queue.sync {
            entries.values.filter { entry in
                keywords.contains { entry.label.contains($0) }
            }.sorted { $0.hitCount > $1.hitCount } // 高命中优先
        }
    }

    /// 查询所有 popup 类缓存（label 含"弹窗""关闭""取消""公告""X"）
    func popupEntries() -> [CoordEntry] {
        query(containsAny: ["弹窗", "关闭", "取消", "公告", "X"])
    }

    /// 导出所有缓存为可编辑 JSON
    func exportJSON() -> String {
        let all = queue.sync { entries.values.sorted { $0.hitCount > $1.hitCount } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    // MARK: - 写入

    /// 写入/更新缓存
    func set(label: String, x: Float, y: Float,
             screenW: Float = 1242, screenH: Float = 2208, source: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let entry = CoordEntry(
                label: label, x: x, y: y,
                screenW: screenW, screenH: screenH,
                hitCount: (self.entries[label]?.hitCount ?? 0) + 1,
                lastHit: Date(),
                source: source
            )
            self.entries[label] = entry
            self.save()
        }
    }

    /// 更新命中计数+时间（缓存命中时调用，不改变坐标）
    func touch(_ label: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self, var entry = self.entries[label] else { return }
            entry.hitCount += 1
            entry.lastHit = Date()
            self.entries[label] = entry
            self.save()
        }
    }

    /// 标记失效（点击后验证失败时调用）
    func invalidate(_ label: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.entries.removeValue(forKey: label)
            self.save()
            Logger.log("CoordCache: 失效删除 [\(label)]")
        }
    }

    /// 用户导入预设坐标
    func importFromUser(_ json: String) {
        guard let data = json.data(using: .utf8),
              let imported = try? JSONDecoder().decode([CoordEntry].self, from: data) else {
            Logger.log("CoordCache: 导入失败，JSON格式错误")
            return
        }
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for entry in imported {
                var e = entry
                if e.hitCount == 0 { e.hitCount = 1 }
                if e.lastHit.timeIntervalSince1970 < 1 { e.lastHit = Date() }
                if e.source.isEmpty { e = CoordEntry(label: e.label, x: e.x, y: e.y,
                                                      screenW: e.screenW, screenH: e.screenH,
                                                      hitCount: e.hitCount, lastHit: e.lastHit,
                                                      source: "manual") }
                self.entries[e.label] = e
            }
            self.save()
            Logger.log("CoordCache: 导入 \(imported.count) 条预设坐标")
        }
    }

    // MARK: - 持久化

    func save() {
        let snapshot = entries
        DispatchQueue.global().async {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: URL(fileURLWithPath: self.cacheFile), options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)),
              let decoded = try? JSONDecoder().decode([String: CoordEntry].self, from: data) else {
            Logger.log("CoordCache: 无缓存文件，使用空库")
            return
        }
        entries = decoded
        Logger.log("CoordCache: 加载 \(entries.count) 条坐标缓存")
    }
}
