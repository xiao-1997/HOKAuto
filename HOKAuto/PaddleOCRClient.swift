import UIKit

/// 百度 PP-OCRv5 云端 OCR 客户端
/// 对应「我不是人机.apk」的 libpaddleocr.so + PaddleOCR 模型
/// 优势：中文识别精度远超 Vision OCR，支持不规则文字框
struct PaddleOCRClient {
    // MARK: - 百度云配置

    /// API Key（从百度智能云控制台获取）
    static var apiKey = ""
    /// Secret Key
    static var secretKey = ""

    private static let tokenURL = "https://aip.baidubce.com/oauth/2.0/token"
    private static let ocrURL = "https://aip.baidubce.com/rest/2.0/ocr/v1/pp_ocrv5"

    /// Token 缓存（30天有效期，提前1天刷新）
    private static var cachedToken: String?
    private static var tokenExpireTime: Date?

    // MARK: - OCR 结果模型

    /// 单行识别结果
    struct LineResult {
        let text: String                    // 识别文字
        let confidence: Float               // 置信度 0~1
        let box: CGRect                     // 矩形包围盒 (像素坐标)
        let polygon: [CGPoint]              // 四边形顶点 (4个点)
    }

    /// 整页识别结果
    struct PageResult {
        let lines: [LineResult]
        let lineCount: Int
    }

    // MARK: - 公开接口

    /// 识别图片中的文字
    /// - Parameters:
    ///   - image: 待识别图片
    ///   - useOrientationClassify: 是否矫正旋转 (0°/90°/180°/270°)
    ///   - useUnwarping: 是否矫正扭曲 (褶皱/倾斜)
    ///   - completion: 回调
    static func recognize(
        image: UIImage,
        useOrientationClassify: Bool = true,
        useUnwarping: Bool = true,
        completion: @escaping (Result<[PageResult], Error>) -> Void
    ) {
        // 图片预处理：压缩到合理尺寸
        guard let imageData = preprocessImage(image) else {
            completion(.failure(NSError(domain: "PaddleOCR", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "图片压缩失败"])))
            return
        }

        // 获取 token 并发起识别
        getToken { tokenResult in
            switch tokenResult {
            case .success(let token):
                performOCR(token: token, imageData: imageData,
                           useOrientationClassify: useOrientationClassify,
                           useUnwarping: useUnwarping,
                           completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 识别图片中的文字（同步版，供 Lua 桥接调用）
    /// - Returns: 识别结果数组，失败返回空
    static func recognizeSync(image: UIImage, timeout: TimeInterval = 8) -> [LineResult] {
        let sem = DispatchSemaphore(value: 0)
        var results: [LineResult] = []

        recognize(image: image) { result in
            if case .success(let pages) = result {
                results = pages.flatMap { $0.lines }
            }
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + timeout)
        return results
    }

    // MARK: - Token 管理

    private static func getToken(completion: @escaping (Result<String, Error>) -> Void) {
        // 命中缓存
        if let token = cachedToken,
           let expireTime = tokenExpireTime,
           Date() < expireTime {
            completion(.success(token))
            return
        }

        guard !apiKey.isEmpty, !secretKey.isEmpty else {
            completion(.failure(NSError(domain: "PaddleOCR", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "请先配置 apiKey 和 secretKey"])))
            return
        }

        let urlStr = "\(tokenURL)?grant_type=client_credentials&client_id=\(apiKey)&client_secret=\(secretKey)"
        guard let url = URL(string: urlStr) else {
            completion(.failure(NSError(domain: "PaddleOCR", code: -3)))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
                Logger.log("PaddleOCR: token获取失败 \(body.prefix(200))")
                completion(.failure(NSError(domain: "PaddleOCR", code: -4)))
                return
            }

            let expiresIn = json["expires_in"] as? Double ?? 2592000 // 默认30天
            cachedToken = token
            tokenExpireTime = Date().addingTimeInterval(expiresIn - 86400) // 提前1天刷新
            Logger.log("PaddleOCR: token获取成功 有效期\(Int(expiresIn/86400))天")
            completion(.success(token))
        }.resume()
    }

    // MARK: - OCR 请求

    private static func performOCR(
        token: String,
        imageData: Data,
        useOrientationClassify: Bool,
        useUnwarping: Bool,
        completion: @escaping (Result<[PageResult], Error>) -> Void
    ) {
        let base64 = imageData.base64EncodedString()
        guard let encoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            completion(.failure(NSError(domain: "PaddleOCR", code: -5)))
            return
        }

        let urlStr = "\(ocrURL)?access_token=\(token)"
        guard let url = URL(string: urlStr) else {
            completion(.failure(NSError(domain: "PaddleOCR", code: -6)))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        // 构建 form body
        var body = "image=\(encoded)"
        if useOrientationClassify { body += "&useDocOrientationClassify=true" }
        if useUnwarping { body += "&useDocUnwarping=true" }
        body += "&useTextlineOrientation=true"
        req.httpBody = body.data(using: .utf8)

        Logger.log("PaddleOCR: 请求识别 (图片\(imageData.count/1024)KB)")

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error {
                Logger.log("PaddleOCR ERR: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(NSError(domain: "PaddleOCR", code: -7)))
                return
            }

            // 检查错误
            if let errCode = json["error_code"] as? Int,
               let errMsg = json["error_msg"] as? String {
                Logger.log("PaddleOCR ERR: [\(errCode)] \(errMsg)")
                // Token 过期，清除缓存
                if errCode == 110 || errCode == 111 {
                    cachedToken = nil
                    tokenExpireTime = nil
                }
                completion(.failure(NSError(domain: "PaddleOCR", code: errCode,
                    userInfo: [NSLocalizedDescriptionKey: errMsg])))
                return
            }

            let pages = parseResponse(json)
            Logger.log("PaddleOCR OK: \(pages.flatMap{$0.lines}.count) 行文字")
            completion(.success(pages))
        }.resume()
    }

    // MARK: - 响应解析

    private static func parseResponse(_ json: [String: Any]) -> [PageResult] {
        guard let pageResults = json["page_result"] as? [[String: Any]] else { return [] }

        return pageResults.compactMap { page in
            let linesRaw = page["lines"] as? [String] ?? []
            let probsRaw = page["probability"] as? [Double] ?? []
            let recBoxesRaw = page["rec_boxes"] as? [[Int]] ?? []
            let recPolysRaw = page["rec_polys"] as? [[[Int]]] ?? []

            let lines: [LineResult] = (0..<linesRaw.count).compactMap { i in
                let text = linesRaw[i]
                let confidence = i < probsRaw.count ? Float(probsRaw[i]) : 0.0

                // 矩形包围盒 [x_min, y_min, x_max, y_max]
                let box: CGRect = {
                    if i < recBoxesRaw.count, recBoxesRaw[i].count >= 4 {
                        let b = recBoxesRaw[i]
                        return CGRect(x: b[0], y: b[1],
                                      width: b[2] - b[0],
                                      height: b[3] - b[1])
                    }
                    return .zero
                }()

                // 四边形顶点 [[x1,y1],[x2,y2],[x3,y3],[x4,y4]]
                let polygon: [CGPoint] = {
                    if i < recPolysRaw.count {
                        return recPolysRaw[i].compactMap { pt in
                            pt.count >= 2 ? CGPoint(x: pt[0], y: pt[1]) : nil
                        }
                    }
                    return []
                }()

                return LineResult(text: text, confidence: confidence,
                                  box: box, polygon: polygon)
            }

            return PageResult(lines: lines, lineCount: lines.count)
        }
    }

    // MARK: - 图片预处理

    private static func preprocessImage(_ image: UIImage) -> Data? {
        // 限制最大边 4096px，保持精度同时控制上传大小
        let maxDim: CGFloat = 4096
        let size = image.size
        var targetSize = size

        if size.width > maxDim || size.height > maxDim {
            let ratio = min(maxDim / size.width, maxDim / size.height)
            targetSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        }

        // 如果不需要缩放，直接用原图
        if targetSize == size {
            return image.jpegData(compressionQuality: 0.85)
        }

        // 缩放
        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resized?.jpegData(compressionQuality: 0.85)
    }

    // MARK: - 配置

    /// 设置 API 凭据
    static func configure(apiKey: String, secretKey: String) {
        self.apiKey = apiKey
        self.secretKey = secretKey
        cachedToken = nil
        tokenExpireTime = nil
        Logger.log("PaddleOCR: 已配置凭据")
    }
}
