import UIKit

/// DeepSeek V4 Pro 文本对话客户端（视觉分析已弃云端，改用本地Vision）
struct DeepSeekClient {
    static let baseURL = "https://api.deepseek.com/v1/chat/completions"
    static let apiKey = "sk-123c8d699d4147898446a34a33b38f8d"

    // MARK: - 文本对话

    static func chat(_ prompt: String, maxTokens: Int = 50,
                     completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "model": "deepseek-v4-pro",
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
            if let error = error {
                Logger.log("chat ERR: \(error.localizedDescription)")
                completion(.failure(error)); return
            }
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
