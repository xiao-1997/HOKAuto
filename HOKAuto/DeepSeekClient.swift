import UIKit

/// DeepSeek API 客户端 (统一 /v1/chat/completions 端点)
/// 文本 + 视觉(VL) 均使用 OpenAI 兼容格式
struct DeepSeekClient {
    static let baseURL = "https://api.deepseek.com/v1/chat/completions"
    static let apiKey = "sk-123c8d699d4147898446a34a33b38f8d"

    // MARK: - 视觉分析 (图片+文本)

    static func analyze(image: UIImage, prompt: String,
                        completion: @escaping (Result<String, Error>) -> Void) {
        guard let data = image.jpegData(compressionQuality: 0.5) else {
            completion(.failure(NSError(domain: "Image", code: -1))); return
        }
        let b64 = data.base64EncodedString()

        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
                ]]
            ],
            "max_tokens": 500
        ]

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 35

        Logger.log("DeepSeek VL: POST \(baseURL)")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error = error {
                Logger.log("DeepSeek VL ERR: \(error.localizedDescription)")
                completion(.failure(error)); return
            }
            if let http = resp as? HTTPURLResponse {
                Logger.log("DeepSeek VL HTTP: \(http.statusCode)")
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion(.failure(NSError(domain: "API", code: -1))); return }

            // 标准响应: choices[0].message.content
            if let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                Logger.log("DeepSeek VL OK: \(content.prefix(100))")
                completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                return
            }

            // 错误
            if let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                Logger.log("DeepSeek VL API Error: \(msg)")
                completion(.failure(NSError(domain: "DeepSeek", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg])))
                return
            }

            completion(.failure(NSError(domain: "API", code: -1)))
        }.resume()
    }

    // MARK: - 文本对话 (连接检测/备用)

    static func chat(_ prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": "返回JSON: {\"ok\":true}"],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 50
        ]

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 5

        Logger.log("DeepSeek chat: POST \(baseURL)")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error = error {
                Logger.log("DeepSeek chat ERR: \(error.localizedDescription)")
                completion(.failure(error)); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String
            else {
                Logger.log("DeepSeek chat PARSE FAIL")
                completion(.failure(NSError(domain: "API", code: -1))); return
            }
            Logger.log("DeepSeek chat OK: \(content.prefix(100))")
            completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }
}
