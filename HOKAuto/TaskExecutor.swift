import UIKit

/// 步骤执行结果
enum StepResult {
    case success(hit: SemanticHit?)
    case retry(attempt: Int, reason: String)
    case failed(reason: String)
    case skipped(reason: String)
}

/// 任务进度
struct TaskProgress {
    let stepIndex: Int
    let totalSteps: Int
    let stepDesc: String
    let status: String        // "执行中", "弹窗处理", "检测目标", "验证中"
}

/// 任务结果
struct TaskResult {
    let success: Bool
    let completedSteps: Int
    let totalSteps: Int
    let failedStep: TaskStep?
    let errorMessage: String?
    let logs: [String]
}

/// 任务执行状态机
class TaskExecutor {
    private let engine: AutomationEngine
    private let yolo: YOLODetector
    private let semantic: SemanticEngine
    private let cache: CoordCache

    private var isCancelled = false
    private var logLines: [String] = []

    init(engine: AutomationEngine, yolo: YOLODetector, semantic: SemanticEngine, cache: CoordCache) {
        self.engine = engine
        self.yolo = yolo
        self.semantic = semantic
        self.cache = cache
    }

    // MARK: - 主入口

    func run(steps: [TaskStep],
             onProgress: @escaping (TaskProgress) -> Void,
             completion: @escaping (TaskResult) -> Void) {
        isCancelled = false
        logLines = []
        log("TaskExecutor: 开始执行 \(steps.count) 步")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var lastFailedStep: TaskStep?
            var completedCount = 0

            for (idx, step) in steps.enumerated() {
                guard !self.isCancelled else {
                    self.log("任务已取消")
                    break
                }

                let progress = TaskProgress(
                    stepIndex: idx + 1, totalSteps: steps.count,
                    stepDesc: step.target, status: "弹窗处理"
                )
                DispatchQueue.main.async { onProgress(progress) }

                // ── 每步前：弹窗消除 ──
                self.dismissPopupsLoop()

                // ── 执行步骤 ──
                let result = self.executeStep(step, stepIndex: idx, total: steps.count, onProgress: onProgress)

                switch result {
                case .success:
                    completedCount += 1
                    lastFailedStep = nil
                case .retry:
                    lastFailedStep = step
                case .failed(let reason):
                    self.log("步骤失败: \(reason)")
                    if step.optional {
                        self.log("可选步骤，跳过")
                        completedCount += 1
                    } else {
                        lastFailedStep = step
                    }
                case .skipped:
                    completedCount += 1
                }

                // 非可选步骤失败 → 终止任务
                if case .failed = result, !step.optional {
                    let taskResult = TaskResult(
                        success: false, completedSteps: completedCount,
                        totalSteps: steps.count, failedStep: step,
                        errorMessage: "步骤「\(step.target)」失败",
                        logs: self.logLines
                    )
                    DispatchQueue.main.async { completion(taskResult) }
                    return
                }
            }

            let taskResult = TaskResult(
                success: lastFailedStep == nil,
                completedSteps: completedCount,
                totalSteps: steps.count,
                failedStep: lastFailedStep,
                errorMessage: lastFailedStep.map { "步骤「\($0.target)」失败" },
                logs: self.logLines
            )
            DispatchQueue.main.async { completion(taskResult) }
        }
    }

    func cancel() { isCancelled = true }

    // MARK: - 单步执行

    private func executeStep(_ step: TaskStep, stepIndex: Int, total: Int,
                             onProgress: @escaping (TaskProgress) -> Void) -> StepResult {

        // 特殊动作：打开应用 / 关闭应用 / 等待
        switch step.action {
        case "open_app":
            log("打开应用: \(step.target)")
            if let url = URL(string: "tencent1104466820://") {
                DispatchQueue.main.async {
                    UIApplication.shared.open(url, options: [:]) { _ in }
                }
            }
            usleep(UInt32(step.waitAfter * 1_000_000))
            return .success(hit: nil)

        case "kill_app":
            log("关闭应用: \(step.target)")
            // 通过 SpringBoard 终止（私有API）
            let cmd = "su mobile -c 'killall -9 tencent1104466820 2>/dev/null; killall -9 mobilechess 2>/dev/null'"
            shell(cmd)
            usleep(UInt32(step.waitAfter * 1_000_000))
            return .success(hit: nil)

        case "wait_until":
            return waitUntil(step: step, onProgress: onProgress)

        case "wait":
            log("等待 \(step.waitAfter)s")
            usleep(UInt32(step.waitAfter * 1_000_000))
            return .success(hit: nil)

        default:
            break
        }

        // 标准点击/输入步骤
        for attempt in 1...step.maxRetries {
            guard !isCancelled else { return .failed(reason: "取消") }

            let progress = TaskProgress(
                stepIndex: stepIndex + 1, totalSteps: total,
                stepDesc: step.target, status: "检测目标(\(attempt)/\(step.maxRetries))"
            )
            DispatchQueue.main.async { onProgress(progress) }

            // 二次弹窗检查（可能在步骤间弹出）
            if attempt > 1 { dismissPopupsLoop() }

            // 截图
            guard let screen = ScreenCapture.capture(maxWidth: 640, quality: 0.7) else {
                log("截图失败")
                return .failed(reason: "截图失败")
            }

            // 三级命中查找目标
            let command = semantic.parse(step.target)
            guard let hit = semantic.findTarget(command: command, cache: cache, screen: screen, yolo: yolo) else {
                log("未找到目标「\(step.target)」(第\(attempt)次)")
                continue
            }
            log("命中: (\(Int(hit.x)),\(Int(hit.y))) [\(hit.source)] conf=\(String(format: "%.2f", hit.confidence))")

            // 点击
            engine.tapNoRecord(hit.x, hit.y)
            usleep(UInt32(step.waitAfter * 1_000_000))

            // 验证
            if let verifyText = step.verifyText {
                let verifyProgress = TaskProgress(
                    stepIndex: stepIndex + 1, totalSteps: total,
                    stepDesc: step.target, status: "验证中"
                )
                DispatchQueue.main.async { onProgress(verifyProgress) }

                let passed = verifyStep(verifyText: verifyText)
                if passed {
                    log("验证通过: \(verifyText)")
                    cache.touch(command.targetLabel)
                    return .success(hit: hit)
                } else {
                    log("验证失败「\(verifyText)」，尝试\(attempt)/\(step.maxRetries)")
                    cache.invalidate(command.targetLabel) // 缓存坐标可能已过时
                }
            } else {
                cache.touch(command.targetLabel)
                return .success(hit: hit)
            }
        }

        // ── 全部重试失败 → DeepSeek 异常恢复 ──
        log("全部\(step.maxRetries)次重试失败，请求 DeepSeek 分析...")
        if let screen = ScreenCapture.capture(maxWidth: 600, quality: 0.4) {
            let ocrResults = LocalVision.ocrSync(image: screen)
            let texts = ocrResults.map { $0.text }

            let sem = DispatchSemaphore(value: 0)
            var suggestion: String?
            DeepSeekClient.analyzeStuck(ocrTexts: texts, failedStep: step) { result in
                if case .success(let json) = result {
                    suggestion = json
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 8)

            if let sug = suggestion {
                log("DeepSeek建议: \(sug.prefix(200))")
            }
        }

        return .failed(reason: "\(step.maxRetries)次重试均未找到目标")
    }

    // MARK: - 等待直到（wait_until）

    private func waitUntil(step: TaskStep, onProgress: @escaping (TaskProgress) -> Void) -> StepResult {
        let keywords = step.verifyText?.components(separatedBy: CharacterSet(charactersIn: ",，、 ")) ?? []
        let maxAttempts = step.maxRetries
        let interval = step.waitAfter

        for attempt in 1...maxAttempts {
            guard !isCancelled else { return .failed(reason: "取消") }

            let progress = TaskProgress(
                stepIndex: 0, totalSteps: 0,
                stepDesc: step.target,
                status: "等待加载(\(attempt)/\(maxAttempts))"
            )
            DispatchQueue.main.async { onProgress(progress) }

            usleep(UInt32(interval * 1_000_000))

            // 弹窗处理
            dismissPopupsLoop()

            guard let screen = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { continue }
            let ocrResults = LocalVision.ocrSync(image: screen)
            let allText = ocrResults.map { $0.text }.joined(separator: " ")

            if keywords.isEmpty || keywords.contains(where: { allText.contains($0) }) {
                log("等待完成: 检测到期望关键词")
                return .success(hit: nil)
            }
        }
        log("等待超时(\(Int(Double(maxAttempts) * interval))s)")
        return .failed(reason: "等待超时")
    }

    // MARK: - 验证

    private func verifyStep(verifyText: String) -> Bool {
        let keywords = verifyText.components(separatedBy: CharacterSet(charactersIn: ",，、 "))
            .filter { !$0.isEmpty }

        guard let screen = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { return false }
        let ocrResults = LocalVision.ocrSync(image: screen)
        let allText = ocrResults.map { $0.text }.joined(separator: " ")

        return keywords.contains { allText.contains($0) }
    }

    // MARK: - 弹窗消除循环

    func dismissPopupsLoop(maxRounds: Int = 3) {
        for round in 1...maxRounds {
            // ① 缓存坐标快速消除
            let cached = cache.popupEntries()
            if !cached.isEmpty {
                for entry in cached.prefix(6) { // 最多点6个
                    engine.tapNoRecord(entry.x, entry.y)
                    usleep(200000)
                }
                usleep(500000)

                // 验证：弹窗是否消失
                guard let screen = ScreenCapture.capture(maxWidth: 600, quality: 0.35) else { return }
                let ocr = LocalVision.ocrSync(image: screen)
                if !semantic.hasPopupKeywords(ocr) {
                    log("弹窗消除(缓存) round\(round)")
                    return
                }
            }

            // ② YOLO + OCR 定位
            guard let screen = ScreenCapture.capture(maxWidth: 640, quality: 0.5) else { return }
            let hits = semantic.findAllPopupButtons(screen: screen, yolo: yolo)
            if !hits.isEmpty {
                for hit in hits {
                    engine.tapNoRecord(hit.x, hit.y)
                    usleep(200000)
                }
                usleep(500000)

                // 写入缓存
                for hit in hits {
                    if hit.source == "ocr" || hit.source == "yolo" {
                        cache.set(label: "弹窗_\(hit.matchedText)", x: hit.x, y: hit.y, source: hit.source)
                    }
                }
            }

            // ③ 纯 OCR 兜底
            let ocrResults = LocalVision.ocrSync(image: screen)
            for (text, rect) in ocrResults {
                if ["关闭", "取消", "确定", "暂不"].contains(where: { text.contains($0) }) {
                    let x = Float(rect.midX * 1242)
                    let y = Float(rect.midY * 2208)
                    engine.tapNoRecord(x, y)
                    usleep(200000)
                    cache.set(label: "弹窗_\(text)", x: x, y: y, source: "ocr")
                }
            }

            // 再次验证
            if let afterScreen = ScreenCapture.capture(maxWidth: 600, quality: 0.35) {
                let after = LocalVision.ocrSync(image: afterScreen)
                if !semantic.hasPopupKeywords(after) {
                    log("弹窗消除 round\(round)")
                    return
                }
            }
        }
        log("弹窗消除: \(maxRounds)轮后仍有弹窗，继续执行")
    }

    // MARK: - Helpers

    private func log(_ msg: String) {
        logLines.append("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)")
        Logger.log("Task: \(msg)")
    }

    private func shell(_ cmd: String) {
        let a: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cmd), nil]
        defer { a.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, nil, a, nil)
        var s: Int32 = 0; waitpid(pid, &s, 0)
    }
}
