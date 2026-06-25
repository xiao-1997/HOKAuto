import UIKit
import Vision

/// 本地视觉引擎: vImage模板匹配 + Vision OCR
struct LocalVision {

    // MARK: - Vision OCR

    static func ocrSync(image: UIImage, timeout: TimeInterval = 3) -> [(text: String, rect: CGRect)] {
        guard let cg = image.cgImage else { return [] }
        let sem = DispatchSemaphore(value: 0)
        var results: [(String, CGRect)] = []

        let req = VNRecognizeTextRequest { req, _ in
            results = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { o -> (String, CGRect)? in
                    guard let t = o.topCandidates(1).first else { return nil }
                    return (t.string, o.boundingBox)
                } ?? []
            sem.signal()
        }
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        _ = sem.wait(timeout: .now() + timeout)
        return results
    }

    /// OCR 关键词检测
    static func detectKeywords(_ image: UIImage) -> [(text: String, x: Float, y: Float)] {
        let kw = ["关闭","取消","确定","暂不","登录","公告","福利","商城","开始","返回"]
        var hits: [(String, Float, Float)] = []
        for (text, rect) in ocrSync(image: image, timeout: 2) {
            if kw.contains(where: { text.contains($0) }) {
                hits.append((text, Float(rect.midX * 1242), Float(rect.midY * 2208)))
            }
        }
        return hits
    }
}
