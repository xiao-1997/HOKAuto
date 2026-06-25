import UIKit
import Vision
import Accelerate

/// 本地视觉引擎: vImage模板匹配 + Vision OCR
struct LocalVision {

    // MARK: - vImage 模板匹配

    static func matchTemplate(screen: UIImage, template: UIImage, threshold: Float = 0.5) -> CGPoint? {
        guard let screenCG = screen.cgImage, let tmplCG = template.cgImage else { return nil }

        // 转灰度 Planar8
        let gray = CGColorSpaceCreateDeviceGray()
        var srcFmt = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 8,
            colorSpace: gray, bitmapInfo: CGBitmapInfo(rawValue: 0))!

        var src = vImage_Buffer(), tmp = vImage_Buffer()
        defer { src.data?.deallocate(); tmp.data?.deallocate() }

        guard vImageBuffer_InitWithCGImage(&src, &srcFmt, nil, screenCG, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              vImageBuffer_InitWithCGImage(&tmp, &srcFmt, nil, tmplCG, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }

        let sw = Int(src.width), sh = Int(src.height)
        let tw = Int(tmp.width), th = Int(tmp.height)
        let rw = sw - tw + 1, rh = sh - th + 1
        guard rw > 0, rh > 0 else { return nil }

        // 结果缓冲 (Float)
        var result = vImage_Buffer()
        result.width = vImagePixelCount(rw)
        result.height = vImagePixelCount(rh)
        result.rowBytes = rw * MemoryLayout<Float>.stride
        result.data = malloc(rh * result.rowBytes)
        defer { free(result.data) }

        guard result.data != nil else { return nil }

        guard vImageNormalizedCrossCorrelation_Planar8(&src, &tmp, &result, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }

        // 找最大相关系数位置
        let floats = result.data.bindMemory(to: Float.self, capacity: rw * rh)
        var maxVal: Float = 0
        var maxIdx = 0
        for i in 0..<(rw * rh) {
            if floats[i] > maxVal { maxVal = floats[i]; maxIdx = i }
        }
        guard maxVal >= threshold else { return nil }

        let cx = CGFloat(maxIdx % rw) + CGFloat(tw) / 2
        let cy = CGFloat(maxIdx / rw) + CGFloat(th) / 2
        return CGPoint(x: cx, y: cy)
    }

    /// 批量模板匹配
    static func matchBest(screen: UIImage, templates: [String], imgDir: String,
                           threshold: Float = 0.5) -> (CGPoint, String)? {
        for name in templates {
            guard let tmpl = UIImage(contentsOfFile: "\(imgDir)/\(name).png") else { continue }
            if let pt = matchTemplate(screen: screen, template: tmpl, threshold: threshold) {
                return (pt, name)
            }
        }
        return nil
    }

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
