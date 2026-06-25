import UIKit

/// DeepSeek VL2 视觉 + deepseek-chat 文本 统一客户端
struct DeepSeekClient {
    static let baseURL = "https://api.deepseek.com/v1/chat/completions"
    static let apiKey = "sk-123c8d699d4147898446a34a33b38f8d"

    // MARK: - VL2 视觉分析 (图片+文本)

    static func analyze(image: UIImage, prompt: String,
                        completion: @escaping (Result<String, Error>) -> Void) {
        guard let data = image.jpegData(compressionQuality: 0.5) else {
            completion(.failure(NSError(domain: "Image", code: -1))); return
        }
        let b64 = data.base64EncodedString()

        let body: [String: Any] = [
            "model": "deepseek-vl2",
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
                ]]
            ],
            "max_tokens": 300
        ]

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 35

        Logger.log("VL2: POST")
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { Logger.log("VL2 ERR: \(error.localizedDescription)"); completion(.failure(error)); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion(.failure(NSError(domain: "API", code: -1))); return }

            if let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                Logger.log("VL2 OK: \(content.prefix(100))")
                completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else if let err = json["error"] as? [String: Any],
                      let m = err["message"] as? String {
                Logger.log("VL2 API Error: \(m)")
                completion(.failure(NSError(domain: "DeepSeek", code: -1, userInfo: [NSLocalizedDescriptionKey: m])))
            } else {
                completion(.failure(NSError(domain: "API", code: -1)))
            }
        }.resume()
    }

    // MARK: - 文本对话

    static func chat(_ prompt: String, maxTokens: Int = 50,
                     completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": "返回JSON: {\"ok\":true}"],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": maxTokens
        ]

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 5

        Logger.log("chat: POST")
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { Logger.log("chat ERR: \(error.localizedDescription)"); completion(.failure(error)); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String
            else { completion(.failure(NSError(domain: "API", code: -1))); return }
            Logger.log("chat OK: \(content.prefix(100))")
            completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }
}
