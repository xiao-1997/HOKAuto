import UIKit

/// 解析后的语义指令
struct ParsedCommand {
    let action: String           // "click", "input_text", "swipe", "wait"
    let targetLabel: String      // CoordCache 缓存键
    let targetText: String       // OCR 匹配文本（提取的核心关键词）
    let targetClass: String?     // YOLO 类别约束（"button", "popup"...）
    let locationHint: String?    // 位置偏好（"左上角", "中间"...）
    let param: String?           // 参数（如金额、密码）
    let rawInput: String
}

/// 语义命中结果
struct SemanticHit {
    let x, y: Float
    let matchedText: String
    let confidence: Float       // 综合评分 0~1
    let source: String          // "cache", "yolo", "ocr"
}

/// 弹窗关键词（用于 dismissPopupsLoop）
private let popupKeywords = ["关闭", "取消", "确定", "暂不", "公告", "X", "知道了", "确定删除"]

/// 语义引擎：中文指令解析 + 三级命中 + YOLO/OCR 融合匹配
class SemanticEngine {

    // MARK: - 中文指令解析

    /// 解析用户输入的自然语言指令
    func parse(_ input: String) -> ParsedCommand {
        var text = input.trimmingCharacters(in: .whitespaces)

        // 1. 提取动作
        var action = "click"
        let actionMap: [(String, String)] = [
            ("点击", "click"), ("点", "click"), ("按", "click"), ("触摸", "click"),
            ("输入", "input_text"), ("填写", "input_text"), ("键入", "input_text"),
            ("滑动", "swipe"), ("滑", "swipe"), ("等待", "wait"), ("打开", "open_app"),
        ]
        for (keyword, act) in actionMap.sorted(by: { $0.0.count > $1.0.count }) {
            if text.contains(keyword) { action = act; text = text.replacingOccurrences(of: keyword, with: " "); break }
        }

        // 2. 提取目标类别
        var targetClass: String? = nil
        let classMap: [(String, String)] = [
            ("按钮", "button"), ("弹窗", "popup"), ("图标", "icon"),
            ("输入框", "input"), ("标签", "tab"), ("开关", "toggle"),
        ]
        for (keyword, cls) in classMap.sorted(by: { $0.0.count > $1.0.count }) {
            if text.contains(keyword) { targetClass = cls; text = text.replacingOccurrences(of: keyword, with: " "); break }
        }

        // 3. 提取位置偏好
        var locationHint: String? = nil
        let locMap: [(String, String)] = [
            ("左上角", "topLeft"), ("右上角", "topRight"), ("左下角", "bottomLeft"),
            ("右下角", "bottomRight"), ("中间", "center"), ("顶部", "top"), ("底部", "bottom"),
        ]
        for (keyword, loc) in locMap.sorted(by: { $0.0.count > $1.0.count }) {
            if text.contains(keyword) { locationHint = loc; text = text.replacingOccurrences(of: keyword, with: " "); break }
        }

        // 4. 提取数字/参数
        var param: String? = nil
        if let match = text.range(of: "\\d+", options: .regularExpression) {
            param = String(text[match])
            text = text.replacingCharacters(in: match, with: " ")
        }

        // 5. 剩余文本 → targetText（去掉标点符号和空格）
        let targetText = text
            .components(separatedBy: CharacterSet.punctuationCharacters.union(.whitespaces))
            .filter { !$0.isEmpty && $0.count >= 1 }
            .joined(separator: "")

        // 6. 生成缓存键
        let labelParts: [String] = [
            targetText.isEmpty ? nil : targetText,
            param.map { "_\($0)" },
            targetClass.map { "_\($0)" },
        ].compactMap { $0 }
        let targetLabel = labelParts.joined()

        return ParsedCommand(
            action: action,
            targetLabel: targetLabel,
            targetText: targetText,
            targetClass: targetClass,
            locationHint: locationHint,
            param: param,
            rawInput: input
        )
    }

    // MARK: - 三级命中主入口

    /// 三级命中策略：缓存 → YOLO+OCR → 纯OCR
    func findTarget(
        command: ParsedCommand,
        cache: CoordCache,
        screen: UIImage,
        yolo: YOLODetector
    ) -> SemanticHit? {

        // ── ① 坐标缓存命中 ──
        if !command.targetLabel.isEmpty, let cached = cache.get(command.targetLabel) {
            Logger.log("语义: 缓存命中 [\(command.targetLabel)] (命中\(cached.hitCount)次)")
            return SemanticHit(x: cached.x, y: cached.y,
                               matchedText: command.targetLabel,
                               confidence: 0.95,
                               source: "cache")
        }

        // ── ② YOLO + OCR 融合匹配 ──
        let detections = yolo.detectSync(image: screen)
        let ocrResults = LocalVision.ocrSync(image: screen)

        if !detections.isEmpty {
            if let hit = matchYOLOwithOCR(
                command: command, detections: detections,
                ocrResults: ocrResults, screen: screen
            ) {
                // 写入缓存（非"cache"来源才写）
                cache.set(label: command.targetLabel, x: hit.x, y: hit.y, source: hit.source)
                return hit
            }
        }

        // ── ③ 纯 OCR 降级 ──
        if !command.targetText.isEmpty, let hit = matchOCRonly(
            command: command, ocrResults: ocrResults, screen: screen
        ) {
            cache.set(label: command.targetLabel, x: hit.x, y: hit.y, source: "ocr")
            return hit
        }

        Logger.log("语义: 三级命中均未找到 [\(command.targetLabel)]")
        return nil
    }

    // MARK: - 弹窗按钮批量查找（用于 dismissPopupsLoop）

    func findAllPopupButtons(screen: UIImage, yolo: YOLODetector) -> [SemanticHit] {
        var hits: [SemanticHit] = []

        let detections = yolo.detectSync(image: screen)
        let ocrResults = LocalVision.ocrSync(image: screen)

        // YOLO 检测到的 close_button / popup → 直接作为候选
        for det in detections where det.classLabel == "close_button" || det.classLabel == "popup" {
            if det.confidence >= 0.3 {
                let x = Float(det.bbox.midX * 1242)
                let y = Float(det.bbox.midY * 2208)
                hits.append(SemanticHit(x: x, y: y, matchedText: det.classLabel,
                                        confidence: det.confidence, source: "yolo"))
            }
        }

        // OCR 匹配弹窗关键词
        for (text, rect) in ocrResults {
            if popupKeywords.contains(where: { text.contains($0) }) {
                let x = Float(rect.midX * 1242)
                let y = Float(rect.midY * 2208)
                // 去重：避免与 YOLO 结果重复
                let tooClose = hits.contains { abs($0.x - x) < 30 && abs($0.y - y) < 30 }
                if !tooClose {
                    hits.append(SemanticHit(x: x, y: y, matchedText: text,
                                            confidence: 0.7, source: "ocr"))
                }
            }
        }

        return hits
    }

    /// 检查 OCR 结果中是否包含弹窗关键词
    func hasPopupKeywords(_ ocrResults: [(text: String, rect: CGRect)]) -> Bool {
        ocrResults.contains { result in
            popupKeywords.contains { result.text.contains($0) }
        }
    }

    // MARK: - YOLO + OCR 融合匹配

    private func matchYOLOwithOCR(
        command: ParsedCommand,
        detections: [YOLODetection],
        ocrResults: [(text: String, rect: CGRect)],
        screen: UIImage
    ) -> SemanticHit? {
        let screenW = Float(screen.size.width * screen.scale)
        let screenH = Float(screen.size.height * screen.scale)

        var candidates: [(hit: SemanticHit, score: Float)] = []

        for det in detections where det.confidence >= 0.25 {
            // 类别约束检查
            if let requiredClass = command.targetClass,
               det.classLabel != requiredClass,
               !isClassRelated(det.classLabel, requiredClass) {
                continue
            }

            // 关联 OCR 文字
            let associatedTexts = associateOCR(detection: det, ocrResults: ocrResults)
            let combinedText = associatedTexts.map { $0.text }.joined()

            // 计算评分
            let score = scoreCandidate(
                command: command,
                detection: det,
                ocrTexts: associatedTexts.map { $0.text },
                combinedText: combinedText,
                screenW: screenW, screenH: screenH
            )

            if score >= 0.30 {
                let x = Float(det.bbox.midX * CGFloat(screenW))
                let y = Float(det.bbox.midY * CGFloat(screenH))
                candidates.append((
                    hit: SemanticHit(x: x, y: y, matchedText: combinedText,
                                     confidence: score, source: "yolo"),
                    score: score
                ))
            }
        }

        return candidates.max(by: { $0.score < $1.score })?.hit
    }

    // MARK: - 纯 OCR 匹配

    private func matchOCRonly(
        command: ParsedCommand,
        ocrResults: [(text: String, rect: CGRect)],
        screen: UIImage
    ) -> SemanticHit? {
        let screenW = Float(screen.size.width * screen.scale)
        let screenH = Float(screen.size.height * screen.scale)

        var best: (hit: SemanticHit, score: Float)?

        for (text, rect) in ocrResults {
            let textScore = textMatchScore(ocrText: text, target: command.targetText)
            guard textScore >= 0.3 else { continue }

            // 类别约束：纯 OCR 无法判断类别，若用户指定了 targetClass 则降分
            var score = textScore * 0.7
            if command.targetClass != nil { score -= 0.15 }

            let x = Float(rect.midX * CGFloat(screenW))
            let y = Float(rect.midY * CGFloat(screenH))

            // 位置加成
            score += locationScore(rect: rect, hint: command.locationHint)

            if score > (best?.score ?? 0) {
                best = (SemanticHit(x: x, y: y, matchedText: text,
                                    confidence: score, source: "ocr"), score)
            }
        }

        return best
    }

    // MARK: - OCR 关联

    /// 将 OCR 文字框关联到 YOLO 检测框
    private func associateOCR(
        detection: YOLODetection,
        ocrResults: [(text: String, rect: CGRect)]
    ) -> [(text: String, overlapRatio: Float)] {
        var associated: [(String, Float)] = []
        for (text, ocrRect) in ocrResults {
            let intersection = detection.bbox.intersection(ocrRect)
            if intersection.isNull { continue }
            let overlap = Float(intersection.width * intersection.height) /
                          Float(ocrRect.width * ocrRect.height)
            if overlap > 0.10 {
                associated.append((text, overlap))
            }
        }
        return associated.sorted { $0.overlapRatio > $1.overlapRatio }
    }

    // MARK: - 评分

    private func scoreCandidate(
        command: ParsedCommand,
        detection: YOLODetection,
        ocrTexts: [String],
        combinedText: String,
        screenW: Float, screenH: Float
    ) -> Float {
        var score: Float = 0

        // YOLO 置信度 (权重 0.35)
        score += detection.confidence * 0.35

        // 类别匹配 (权重 0.35)
        if let requiredClass = command.targetClass {
            if detection.classLabel == requiredClass {
                score += 0.35
            } else if isClassRelated(detection.classLabel, requiredClass) {
                score += 0.20
            }
        } else {
            score += 0.15 // 无约束时给底分
        }

        // 文字匹配 (权重 0.20)
        if !command.targetText.isEmpty {
            let bestTextScore = ocrTexts.map { textMatchScore(ocrText: $0, target: command.targetText) }.max() ?? 0
            score += bestTextScore * 0.20
        }

        // 历史命中加成 (权重 0.10)
        // 由 CoordCache.get 处理，这里给底分

        return min(score, 1.0)
    }

    /// 文字匹配评分
    private func textMatchScore(ocrText: String, target: String) -> Float {
        if ocrText == target { return 1.0 }
        if ocrText.contains(target) { return 0.9 }
        if target.contains(ocrText) { return 0.7 }
        // 字符重叠率
        let ocrChars = Set(ocrText)
        let targetChars = Set(target)
        let overlap = Float(ocrChars.intersection(targetChars).count)
        let total = Float(targetChars.count)
        if total > 0 { return overlap / total * 0.6 }
        return 0
    }

    /// 位置评分
    private func locationScore(rect: CGRect, hint: String?) -> Float {
        guard let hint = hint else { return 0.05 } // 无偏好，微小幅中心奖励

        let cx = rect.midX, cy = rect.midY
        switch hint {
        case "topLeft":     return (1.0 - Float(cx + cy) / 2) * 0.10
        case "topRight":    return (Float(cx) + (1.0 - Float(cy))) / 2 * 0.10
        case "bottomLeft":  return ((1.0 - Float(cx)) + Float(cy)) / 2 * 0.10
        case "bottomRight": return Float(cx + cy) / 2 * 0.10
        case "top":         return (1.0 - Float(cy)) * 0.10
        case "bottom":      return Float(cy) * 0.10
        case "center":      return (1.0 - abs(Float(cx - 0.5)) - abs(Float(cy - 0.5))) * 0.10
        default:            return 0.05
        }
    }

    /// 判断两个 YOLO 类别是否语义相关
    private func isClassRelated(_ a: String, _ b: String) -> Bool {
        let groups: [Set<String>] = [
            ["button", "close_button", "tab"],
            ["popup", "button"],
            ["icon", "badge"],
        ]
        return groups.contains { $0.contains(a) && $0.contains(b) }
    }
}
