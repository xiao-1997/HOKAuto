import UIKit

/// DeepSeek VL 视觉语言模型客户端
/// API: https://api.deepseek.international/v1/vision
struct DeepSeekClient {
    static let visionURL = "https://api.deepseek.international/v1/vision"
    static let apiKey = "sk-123c8d699d4147898446a34a33b38f8d"

    // MARK: - Vision API (图片+文本 → 文本)

    /// 发送截图到 DeepSeek VL 分析
    static func analyze(image: UIImage, prompt: String,
                        completion: @escaping (Result<String, Error>) -> Void) {
        guard let data = image.jpegData(compressionQuality: 0.5) else {
            completion(.failure(NSError(domain: "Image", code: -1))); return
        }
        let b64 = data.base64EncodedString()
        let imageDataURL = "data:image/jpeg;base64,\(b64)"

        let body: [String: Any] = [
            "image_url": imageDataURL,
            "prompt": prompt,
            "mode": "analyze",
            "output_format": "json"
        ]

        var req = URLRequest(url: URL(string: visionURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 25

        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error = error { completion(.failure(error)); return }

            guard let data = data else {
                completion(.failure(NSError(domain: "API", code: -1))); return
            }

            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

            // 格式1: { "output": "..." }
            if let output = json?["output"] as? String {
                completion(.success(output.trimmingCharacters(in: .whitespacesAndNewlines)))
                return
            }

            // 格式2: { "choices": [{ "message": { "content": "..." } }] }
            if let choices = json?["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                return
            }

            // 错误
            if let err = json?["error"] as? [String: Any],
               let msg = err["message"] as? String {
                completion(.failure(NSError(domain: "DeepSeek", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg])))
                return
            }

            // Raw
            if let raw = String(data: data, encoding: .utf8) {
                completion(.success(raw))
            } else {
                completion(.failure(NSError(domain: "API", code: -1)))
            }
        }.resume()
    }

    // MARK: - Text Chat (备用)

    static func chat(_ prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": "王者荣耀自动化助手。返回JSON: {\"action\":\"click\",\"x\":数字,\"y\":数字}"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": 300
        ]

        var req = URLRequest(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String
            else { completion(.failure(NSError(domain: "API", code: -1))); return }
            completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }
}
