import UIKit
import Vision
import CoreML

/// Lua 视觉桥接层
/// 仿「我不是人机.apk」的 YOLO + PaddleOCR + Tesseract 多引擎架构
/// iOS 等价实现: Vision OCR + CoreML YOLO + vImage 模板匹配 + DeepSeek
///
/// 通信协议:
///   Lua 写入请求文件 → Swift 轮询处理 → 写入响应文件
///
/// 请求类型:
///   OCR:     /tmp/hok_ocr_req.txt      → /tmp/hok_ocr_resp.json   (Vision 本地)
///   Paddle:  /tmp/hok_paddle_req.txt   → /tmp/hok_paddle_resp.json (百度云)
///   YOLO:    /tmp/hok_yolo_req.txt     → /tmp/hok_yolo_resp.json
///   DeepSeek:/tmp/hok_ds_req.txt       → /tmp/hok_ds_resp.json
///   输入:    /tmp/hok_input_req.txt    → /tmp/hok_input_done.txt
class LuaVisionBridge {
    static let shared = LuaVisionBridge()

    private var watchTimer: Timer?
    private var yoloModel: VNCoreMLModel?

    /// 是否启用百度 PP-OCRv5 云端 OCR（需要先配置 PaddleOCRClient.apiKey/secretKey）
    var usePaddleOCR = false

    // 文件监控间隔
    private let pollInterval: TimeInterval = 0.5

    // MARK: - 启动桥接服务

    func start() {
        Logger.log("LuaVisionBridge: 启动视觉桥接服务")
        yoloModel = YOLODetector().loadModelCompat()

        watchTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollAllRequests()
        }
    }

    func stop() {
        watchTimer?.invalidate()
        watchTimer = nil
        Logger.log("LuaVisionBridge: 已停止")
    }

    // MARK: - 轮询所有请求类型

    private func pollAllRequests() {
        handleOCRRequest()
        handlePaddleOCRRequest()
        handleYOLORequest()
        handleDeepSeekRequest()
        handleInputRequest()
    }

    // MARK: - 引擎1: OCR 请求

    private func handleOCRRequest() {
        let reqFile = "/tmp/hok_ocr_req.txt"
        let respFile = "/tmp/hok_ocr_resp.json"
        let screenFile = "/tmp/hok_ocr_screen.png"

        guard FileManager.default.fileExists(atPath: reqFile),
              let keywordsStr = try? String(contentsOfFile: reqFile, encoding: .utf8) else {
            return
        }

        // 读取截图
        guard let screenImg = UIImage(contentsOfFile: screenFile),
              let cgImage = screenImg.cgImage else {
            writeOCRResponse(path: respFile, results: [])
            cleanup(reqFile, screenFile)
            return
        }

        let keywords = keywordsStr.components(separatedBy: "|").filter { !$0.isEmpty }
        Logger.log("LuaBridge OCR: 检测关键词 \(keywords)")

        // Vision OCR
        let sem = DispatchSemaphore(value: 0)
        var hits: [[String: Any]] = []

        let request = VNRecognizeTextRequest { req, _ in
            let observations = (req.results as? [VNRecognizedTextObservation]) ?? []

            for obs in observations {
                guard let top = obs.topCandidates(1).first else { continue }
                let text = top.string
                // 匹配关键词
                for kw in keywords {
                    if text.contains(kw) {
                        let rect = obs.boundingBox
                        // 归一化坐标 → 逻辑像素 (1242x2208)
                        let x = rect.midX * 1242
                        let y = (1 - rect.midY) * 2208  // Vision坐标系翻转
                        let w = rect.width * 1242
                        let h = rect.height * 2208
                        hits.append([
                            "text": text,
                            "x": Int(x),
                            "y": Int(y),
                            "w": Int(w),
                            "h": Int(h),
                        ])
                        break
                    }
                }
            }
            sem.signal()
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        _ = sem.wait(timeout: .now() + 3)

        writeOCRResponse(path: respFile, results: hits)
        cleanup(reqFile, screenFile)
        Logger.log("LuaBridge OCR: 命中 \(hits.count) 个关键词")
    }

    // MARK: - 引擎1b: 百度 PP-OCRv5 云端 OCR

    private func handlePaddleOCRRequest() {
        let reqFile = "/tmp/hok_paddle_req.txt"
        let respFile = "/tmp/hok_paddle_resp.json"
        let screenFile = "/tmp/hok_paddle_screen.png"

        guard usePaddleOCR,
              FileManager.default.fileExists(atPath: reqFile),
              let keywordsStr = try? String(contentsOfFile: reqFile, encoding: .utf8) else {
            return
        }

        guard let screenImg = UIImage(contentsOfFile: screenFile) else {
            writeOCRResponse(path: respFile, results: [])
            cleanup(reqFile, screenFile)
            return
        }

        let keywords = keywordsStr.components(separatedBy: "|").filter { !$0.isEmpty }
        Logger.log("LuaBridge PaddleOCR: 检测关键词 \(keywords)")

        // 使用百度 PP-OCRv5 云端识别
        PaddleOCRClient.recognize(image: screenImg) { result in
            var hits: [[String: Any]] = []

            switch result {
            case .success(let pages):
                for page in pages {
                    for line in page.lines {
                        // 匹配关键词
                        for kw in keywords {
                            if line.text.contains(kw) {
                                // rec_boxes 坐标 → 逻辑像素映射
                                // PaddleOCR 返回的是图片实际像素坐标
                                let scaleX: CGFloat = 1242.0 / screenImg.size.width
                                let scaleY: CGFloat = 2208.0 / screenImg.size.height
                                let x = Int(line.box.midX * scaleX)
                                let y = Int(line.box.midY * scaleY)
                                let w = Int(line.box.width * scaleX)
                                let h = Int(line.box.height * scaleY)

                                hits.append([
                                    "text": line.text,
                                    "x": x,
                                    "y": y,
                                    "w": w,
                                    "h": h,
                                    "conf": Double(line.confidence),
                                ])
                                break
                            }
                        }
                    }
                }
                Logger.log("LuaBridge PaddleOCR: 命中 \(hits.count) 个关键词 (共\(pages.flatMap{$0.lines}.count)行)")

            case .failure(let err):
                Logger.log("LuaBridge PaddleOCR ERR: \(err.localizedDescription)")
            }

            self.writeOCRResponse(path: respFile, results: hits)
            self.cleanup(reqFile, screenFile)
        }
    }

    private func writeOCRResponse(path: String, results: [[String: Any]]) {
        var json = "["
        for (i, hit) in results.enumerated() {
            if i > 0 { json += "," }
            if let data = try? JSONSerialization.data(withJSONObject: hit),
               let str = String(data: data, encoding: .utf8) {
                json += str
            }
        }
        json += "]"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 引擎2: YOLO 请求

    private func handleYOLORequest() {
        let reqFile = "/tmp/hok_yolo_req.txt"
        let respFile = "/tmp/hok_yolo_resp.json"
        let screenFile = "/tmp/hok_yolo_screen.png"

        guard FileManager.default.fileExists(atPath: reqFile),
              let classesStr = try? String(contentsOfFile: reqFile, encoding: .utf8),
              let model = yoloModel else {
            return
        }

        guard let screenImg = UIImage(contentsOfFile: screenFile),
              let cgImage = screenImg.cgImage else {
            writeYOLOResponse(path: respFile, results: [])
            cleanup(reqFile, screenFile)
            return
        }

        let targetClasses = Set(classesStr.components(separatedBy: ",").filter { !$0.isEmpty })
        Logger.log("LuaBridge YOLO: 检测类别 \(targetClasses)")

        let sem = DispatchSemaphore(value: 0)
        var detections: [[String: Any]] = []

        let request = VNCoreMLRequest(model: model) { req, _ in
            let observations = (req.results as? [VNRecognizedObjectObservation]) ?? []

            for obs in observations {
                guard let label = obs.labels.first else { continue }
                guard targetClasses.isEmpty || targetClasses.contains(label.identifier) else { continue }
                guard label.confidence >= 0.25 else { continue }

                let rect = obs.boundingBox
                let x = rect.midX * 1242
                let y = (1 - rect.midY) * 2208
                let w = rect.width * 1242
                let h = rect.height * 2208

                detections.append([
                    "class": label.identifier,
                    "x": Int(x),
                    "y": Int(y),
                    "w": Int(w),
                    "h": Int(h),
                    "conf": Double(label.confidence),
                ])
            }
            sem.signal()
        }
        request.imageCropAndScaleOption = .scaleFill

        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        _ = sem.wait(timeout: .now() + 2)

        writeYOLOResponse(path: respFile, results: detections)
        cleanup(reqFile, screenFile)
        Logger.log("LuaBridge YOLO: 检测到 \(detections.count) 个目标")
    }

    private func writeYOLOResponse(path: String, results: [[String: Any]]) {
        var json = "["
        for (i, det) in results.enumerated() {
            if i > 0 { json += "," }
            if let data = try? JSONSerialization.data(withJSONObject: det),
               let str = String(data: data, encoding: .utf8) {
                json += str
            }
        }
        json += "]"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 引擎3: DeepSeek AI 请求

    private func handleDeepSeekRequest() {
        let reqFile = "/tmp/hok_ds_req.txt"
        let respFile = "/tmp/hok_ds_resp.json"
        let screenFile = "/tmp/hok_ds_screen.png"

        guard FileManager.default.fileExists(atPath: reqFile),
              let prompt = try? String(contentsOfFile: reqFile, encoding: .utf8) else {
            return
        }

        guard let screenImg = UIImage(contentsOfFile: screenFile) else {
            writeDSResponse(path: respFile, action: "none", x: 0, y: 0)
            cleanup(reqFile, screenFile)
            return
        }

        Logger.log("LuaBridge DeepSeek: \(prompt.prefix(80))")

        DeepSeekClient.analyzeScreen(screenImage: screenImg, prompt: prompt) { result in
            switch result {
            case .success(let json):
                self.writeDSResponse(path: respFile, json: json)
            case .failure:
                self.writeDSResponse(path: respFile, action: "none", x: 0, y: 0)
            }
            self.cleanup(reqFile, screenFile)
        }
    }

    private func writeDSResponse(path: String, action: String, x: Int, y: Int) {
        let json = """
        {"action":"\(action)","x":\(x),"y":\(y)}
        """
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func writeDSResponse(path: String, json: String) {
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 引擎4: 文本输入请求

    private func handleInputRequest() {
        let reqFile = "/tmp/hok_input_req.txt"
        let respFile = "/tmp/hok_input_done.txt"

        guard FileManager.default.fileExists(atPath: reqFile),
              let text = try? String(contentsOfFile: reqFile, encoding: .utf8) else {
            return
        }

        Logger.log("LuaBridge Input: \(text.prefix(20))")

        // 通过粘贴板注入文本
        UIPasteboard.general.string = text

        // 模拟 cmd+V (在越狱设备上通过 autotouch 实现)
        // 或者通过 UIKeyCommand
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // 通知输入完成
            try? "done".write(toFile: respFile, atomically: true, encoding: .utf8)
        }
        cleanup(reqFile)
    }

    // MARK: - 辅助

    private func cleanup(_ files: String...) {
        for f in files {
            try? FileManager.default.removeItem(atPath: f)
        }
    }
}

// MARK: - YOLODetector 扩展

extension YOLODetector {
    /// 兼容方式加载模型（用于 LuaBridge）
    func loadModelCompat() -> VNCoreMLModel? {
        let name = "yolov8n_ui"
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") ??
                         Bundle.main.url(forResource: name, withExtension: "mlmodel") else {
            Logger.log("LuaBridge YOLO: 模型文件未找到")
            return nil
        }
        do {
            let mlModel = try MLModel(contentsOf: url)
            let visionModel = try VNCoreMLModel(for: mlModel)
            Logger.log("LuaBridge YOLO: 模型加载成功")
            return visionModel
        } catch {
            Logger.log("LuaBridge YOLO: 模型加载失败 \(error)")
            return nil
        }
    }
}

// MARK: - DeepSeekClient 扩展

extension DeepSeekClient {
    /// 分析屏幕截图（供 Lua 桥接调用）
    /// 优先用百度 PP-OCRv5（中文精度高）→ 降级 Vision OCR（本地离线）
    /// 提取文字后用 DeepSeek 文本对话分析
    static func analyzeScreen(screenImage: UIImage, prompt: String,
                               completion: @escaping (Result<String, Error>) -> Void) {
        // 检查是否配置了 PaddleOCR
        let usePaddle = !PaddleOCRClient.apiKey.isEmpty && !PaddleOCRClient.secretKey.isEmpty

        if usePaddle {
            // 引擎1: 百度 PP-OCRv5（中文精度最高）
            PaddleOCRClient.recognize(image: screenImage) { result in
                let screenDesc: String
                switch result {
                case .success(let pages):
                    let lines = pages.flatMap { $0.lines }.map { $0.text }
                    screenDesc = lines.isEmpty ? "(无文字)" : lines.joined(separator: " | ")
                    Logger.log("DeepSeek+PaddleOCR: \(lines.count) 行文字")
                case .failure:
                    screenDesc = "(PaddleOCR失败)"
                }
                analyzeWithText(screenDesc: screenDesc, prompt: prompt, completion: completion)
            }
        } else {
            // 引擎2: Vision OCR 降级
            guard let cgImage = screenImage.cgImage else {
                completion(.failure(NSError(domain: "OCR", code: -1)))
                return
            }
            let sem = DispatchSemaphore(value: 0)
            var ocrTexts: [String] = []
            let req = VNRecognizeTextRequest { request, _ in
                ocrTexts = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                sem.signal()
            }
            req.recognitionLevel = .fast
            req.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cgImage).perform([req])
            _ = sem.wait(timeout: .now() + 3)

            let screenDesc = ocrTexts.isEmpty ? "(无文字)" : ocrTexts.joined(separator: " | ")
            Logger.log("DeepSeek+VisionOCR: \(ocrTexts.count) 行文字")
            analyzeWithText(screenDesc: screenDesc, prompt: prompt, completion: completion)
        }
    }

    /// DeepSeek 文本对话（OCR 结果 → 坐标决策）
    private static func analyzeWithText(screenDesc: String, prompt: String,
                                         completion: @escaping (Result<String, Error>) -> Void) {
        let systemPrompt = """
        你是游戏自动化视觉助手。根据屏幕OCR文字分析当前状态。
        屏幕逻辑分辨率: 1242x2208 (iPhone Plus)。

        请返回严格JSON格式（只返回JSON，不要其他文字）:
        {
          "action": "click" 或 "none",
          "x": 点击X坐标(整数),
          "y": 点击Y坐标(整数),
          "reason": "操作原因(中文,15字以内)"
        }

        如果OCR文字中没有可操作的目标，返回 action="none"。
        常见按钮位置参考: 关闭按钮通常在右上角(x≈1800-2100, y≈100-200)
        取消按钮通常在弹窗中部偏下(x≈600-1800, y≈600-1000)
        确认按钮通常在弹窗底部(x≈600-1800, y≈1300-1800)
        """

        let textPrompt = """
        任务: \(prompt)

        屏幕OCR文字内容:
        \(screenDesc)

        请根据OCR文字判断当前屏幕状态，找到目标按钮的坐标。
        """

        chat(textPrompt, systemPrompt: systemPrompt, maxTokens: 300, completion: completion)
    }
}
