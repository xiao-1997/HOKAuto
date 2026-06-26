import UIKit
import Vision
import CoreML

/// YOLO 目标检测结果
struct YOLODetection {
    let classLabel: String      // "button", "popup", "close_btn", "tab", "icon", "badge", "input"
    let confidence: Float       // 0~1
    let bbox: CGRect            // 归一化坐标 (0~1)
    let classIndex: Int
}

/// YOLO 检测器：加载 Core ML 模型，通过 Vision 执行目标检测
class YOLODetector {
    private var visionModel: VNCoreMLModel?
    private var isLoaded = false

    /// 已知类别列表（需与模型训练时的类别顺序一致）
    let classLabels = [
        "button",        // 0: 通用可点击按钮
        "close_button",  // 1: 关闭/取消按钮
        "popup",         // 2: 弹窗/对话框
        "tab",           // 3: 标签页/导航按钮
        "icon",          // 4: 图标（英雄头像、道具图标）
        "badge",         // 5: 红点/角标
        "input",         // 6: 输入框
    ]

    // MARK: - 模型加载

    func loadModel(named name: String = "yolov8n_ui", from bundle: Bundle = .main) -> Bool {
        guard !isLoaded else { return true }

        // 优先加载编译后的 .mlmodelc
        if let url = bundle.url(forResource: name, withExtension: "mlmodelc") ??
                     bundle.url(forResource: name, withExtension: "mlmodel") {
            do {
                let mlModel = try MLModel(contentsOf: url)
                visionModel = try VNCoreMLModel(for: mlModel)
                isLoaded = true
                Logger.log("YOLO: 模型加载成功 \(url.lastPathComponent)")
                return true
            } catch {
                Logger.log("YOLO: 模型加载失败 \(error.localizedDescription)")
                return false
            }
        }
        Logger.log("YOLO: 模型文件未找到 [\(name).mlmodelc]")
        return false
    }

    func unloadModel() {
        visionModel = nil
        isLoaded = false
        Logger.log("YOLO: 模型已释放")
    }

    // MARK: - 同步检测

    /// 同步执行目标检测（内部使用 Semaphore 等待异步 Vision 回调）
    func detectSync(image: UIImage, timeout: TimeInterval = 1.5) -> [YOLODetection] {
        guard isLoaded, let model = visionModel else {
            Logger.log("YOLO: 模型未加载，跳过检测")
            return []
        }
        guard let cgImage = image.cgImage else {
            Logger.log("YOLO: CGImage 获取失败")
            return []
        }

        let semaphore = DispatchSemaphore(value: 0)
        var detections: [YOLODetection] = []

        let request = VNCoreMLRequest(model: model) { request, error in
            defer { semaphore.signal() }

            if let error = error {
                Logger.log("YOLO: 推理失败 \(error.localizedDescription)")
                return
            }
            detections = (request.results as? [VNRecognizedObjectObservation])?
                .compactMap { obs -> YOLODetection? in
                    guard let label = obs.labels.first else { return nil }
                    return YOLODetection(
                        classLabel: label.identifier,
                        confidence: label.confidence,
                        bbox: obs.boundingBox,
                        classIndex: self.classLabels.firstIndex(of: label.identifier) ?? -1
                    )
                } ?? []
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Logger.log("YOLO: VNImageRequestHandler 失败 \(error.localizedDescription)")
            return []
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        Logger.log("YOLO: 检测到 \(detections.count) 个目标")
        return detections
    }

    // MARK: - 异步检测

    func detect(image: UIImage, completion: @escaping ([YOLODetection]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let results = self.detectSync(image: image)
            DispatchQueue.main.async { completion(results) }
        }
    }

    // MARK: - 过滤

    /// 按类别和最低置信度过滤
    func filter(_ detections: [YOLODetection],
                classes: Set<String>? = nil,
                minConfidence: Float = 0.3) -> [YOLODetection] {
        detections.filter { det in
            let classOK = classes?.contains(det.classLabel) ?? true
            return classOK && det.confidence >= minConfidence
        }.sorted { $0.confidence > $1.confidence }
    }
}
