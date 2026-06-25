import UIKit
import Vision
import Accelerate

/// 本地视觉引擎: Vision OCR + 图像预处理
struct LocalVision {

    // MARK: - Vision OCR

    static func ocr(image: UIImage, completion: @escaping ([(text: String, rect: CGRect)]) -> Void) {
        guard let cg = image.cgImage else { completion([]); return }
        let req = VNRecognizeTextRequest { req, _ in
            let r = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { o -> (String, CGRect)? in
                    guard let t = o.topCandidates(1).first else { return nil }
                    return (t.string, o.boundingBox)
                } ?? []
            completion(r)
        }
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg).perform([req])
    }

    static func ocrSync(image: UIImage, timeout: TimeInterval = 3) -> [(text: String, rect: CGRect)] {
        let sem = DispatchSemaphore(value: 0)
        var r: [(String, CGRect)] = []
        ocr(image: image) { r = $0; sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        return r
    }

    // MARK: - 图像预处理

    /// 转灰度
    static func grayscale(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.draw(cg, in: CGRect(x:0,y:0,width:cg.width,height:cg.height))
        guard let out = ctx?.makeImage() else { return nil }
        return UIImage(cgImage: out)
    }

    // MARK: - OCR关键词检测

    static func detectKeywords(_ image: UIImage) -> [(text: String, x: Float, y: Float)] {
        let kw = ["关闭","取消","确定","暂不","登录","公告","福利","商城","开始","返回"]
        var hits: [(String, Float, Float)] = []
        for (text, rect) in ocrSync(image: image, timeout: 2) {
            if kw.contains(where: { text.contains($0) }) {
                let x = Float(rect.midX * 1242)
                let y = Float(rect.midY * 2208)
                hits.append((text, x, y))
            }
        }
        return hits
    }
}
