import UIKit
import Vision
import Accelerate

/// 本地视觉引擎：vImage模板匹配 + Vision OCR
struct LocalVision {

    // MARK: - vImage 模板匹配

    /// 在屏幕截图中查找模板图片，返回匹配中心坐标
    static func matchTemplate(screen: UIImage, template: UIImage, threshold: Float = 0.6) -> CGPoint? {
        guard let screenCG = screen.cgImage, let tmplCG = template.cgImage else { return nil }

        let sw = screenCG.width, sh = screenCG.height
        let tw = tmplCG.width, th = tmplCG.height
        guard tw <= sw, th <= sh else { return nil }

        // 转灰度 vImage 缓冲
        guard var src = vImage_Buffer(), var tmp = vImage_Buffer() else { return nil }

        let srcFmt = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 8,
            colorSpace: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))!

        var err = vImageBuffer_InitWithCGImage(&src, &srcFmt, nil, screenCG, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return nil }

        err = vImageBuffer_InitWithCGImage(&tmp, &srcFmt, nil, tmplCG, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { free(src.data); return nil }
        defer { free(src.data); free(tmp.data) }

        // 归一化互相关匹配
        let resultW = sw - tw + 1, resultH = sh - th + 1
        guard var result = vImage_Buffer() else { return nil }
        result.width = vImagePixelCount(resultW)
        result.height = vImagePixelCount(resultH)
        result.rowBytes = resultW * MemoryLayout<Float>.size
        result.data = calloc(resultH, result.rowBytes)
        guard result.data != nil else { return nil }

        err = vImageNormalizedCrossCorrelation_ARGB8888(&src, &tmp, &result, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { free(result.data); return nil }
        defer { free(result.data) }

        // 找最大值位置
        let floats = result.data.assumingMemoryBound(to: Float.self)
        var maxVal: Float = 0; var maxIdx: vImagePixelCount = 0
        for i in 0..<resultW * resultH {
            if floats[i] >= maxVal { maxVal = floats[i]; maxIdx = i }
        }

        guard maxVal >= threshold else { return nil }

        let cx = CGFloat(maxIdx % resultW) + CGFloat(tw) / 2
        let cy = CGFloat(maxIdx / resultW) + CGFloat(th) / 2
        return CGPoint(x: cx / screen.scale, y: cy / screen.scale)
    }

    /// 批量模板匹配：尝试多张模板，命中返回坐标
    static func matchBest(screen: UIImage, templates: [String], imgDir: String,
                           threshold: Float = 0.5) -> (CGPoint, String)? {
        for name in templates {
            let path = "\(imgDir)/\(name).png"
            guard let tmpl = UIImage(contentsOfFile: path) else { continue }
            if let pt = matchTemplate(screen: screen, template: tmpl, threshold: threshold) {
                return (pt, name)
            }
        }
        return nil
    }

    // MARK: - Vision OCR 文字识别

    /// 识别图片中的文字，返回文字+位置
    static func ocr(image: UIImage, completion: @escaping ([(text: String, rect: CGRect)]) -> Void) {
        guard let cgImage = image.cgImage else { completion([]); return }

        let req = VNRecognizeTextRequest { request, _ in
            guard let obs = request.results as? [VNRecognizedTextObservation] else {
                completion([]); return
            }
            let results = obs.compactMap { o -> (String, CGRect)? in
                guard let top = o.topCandidates(1).first else { return nil }
                return (top.string, o.boundingBox)
            }
            completion(results)
        }
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([req])
    }

    /// 同步 OCR (信号量包装)
    static func ocrSync(image: UIImage, timeout: TimeInterval = 3) -> [(text: String, rect: CGRect)] {
        let sem = DispatchSemaphore(value: 0)
        var results: [(String, CGRect)] = []
        ocr(image: image) { r in results = r; sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        return results
    }

    // MARK: - 图像预处理

    /// 转灰度
    static func grayscale(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let grayCG = ctx?.makeImage() else { return nil }
        return UIImage(cgImage: grayCG, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 边缘检测 (Sobel)
    static func edgeDetect(_ image: UIImage) -> UIImage? {
        let filter = CIFilter(name: "CIEdgeWork")
        filter?.setValue(CIImage(image: image), forKey: kCIInputImageKey)
        filter?.setValue(3.0, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage else { return nil }
        return UIImage(ciImage: output)
    }

    // MARK: - 按钮检测

    /// 综合检测：模板+OCR返回所有候选按钮
    static func detectButtons(screen: UIImage, templates: [String], imgDir: String) -> [(name: String, x: Float, y: Float)] {
        var buttons: [(String, Float, Float)] = []

        // 1. 模板匹配
        for name in templates {
            let path = "\(imgDir)/\(name).png"
            guard let tmpl = UIImage(contentsOfFile: path) else { continue }
            if let pt = matchTemplate(screen: screen, template: tmpl, threshold: 0.5) {
                buttons.append((name, Float(pt.x), Float(pt.y)))
            }
        }

        // 2. OCR 检测关闭/取消等关键词
        let texts = ocrSync(image: screen, timeout: 2)
        for (text, rect) in texts {
            if text.contains("关闭") || text.contains("取消") || text.contains("确定") ||
               text.contains("暂不") || text.contains("登录") {
                let x = Float(rect.midX * screen.size.width)
                let y = Float(rect.midY * screen.size.height)
                buttons.append(("ocr_\(text.prefix(4))", x, y))
            }
        }

        return buttons
    }
}
