import UIKit

/// DeepSeek AI 语义分析客户端
struct DeepSeekClient {
    static let baseURL = "https://api.deepseek.com"
    static var apiKey = "sk-123c8d699d4147898446a34a33b38f8d"

    // MARK: - 语义分析

    /// 分析屏幕状态，返回操作建议
    static func analyzeScreen(context: [String: Any],
                              completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let prompt = """
        你是王者荣耀游戏自动化助手。屏幕分辨率1242x2208横屏。
        当前状态: \(context["status"] as? String ?? "未知")
        检测到的按钮: \(context["buttons"] as? String ?? "无")
        最近操作: \(context["lastAction"] as? String ?? "无")

        请返回JSON操作指令: {"action":"click"/"swipe"/"wait","target":"按钮名称","x":0,"y":0,"reason":"分析原因"}
        """

        chat(prompt) { result in
            switch result {
            case .success(let text):
                if let json = extractJSON(from: text),
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    completion(.success(dict))
                } else {
                    completion(.success(["raw": text]))
                }
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    /// 弹窗识别分析
    static func analyzePopup(visibleTexts: [String],
                             completion: @escaping (Result<String, Error>) -> Void) {
        let textList = visibleTexts.joined(separator: "、")
        let prompt = """
        王者荣耀弹窗分析。可见文字: \(textList.isEmpty ? "无" : textList)
        返回JSON: {"type":"close"/"cancel"/"skip"/"ok"/"none","reason":"分析"}
        """
        chat(prompt) { result in
            switch result {
            case .success(let text):
                if let json = extractJSON(from: text) {
                    completion(.success(json))
                } else {
                    completion(.success("{\"type\":\"none\"}"))
                }
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    // MARK: - Image Chat (DeepSeek vision)

    static func chatWithImage(prompt: String, base64Image: String,
                               completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": "王者荣耀自动化。返回JSON坐标: {\"action\":\"click\",\"x\":数字,\"y\":数字}"],
                ["role": "user", "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + base64Image]]
                ]]
            ],
            "temperature": 0.1,
            "max_tokens": 300
        ]

        var req = URLRequest(url: URL(string: "\(baseURL)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20

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

    // MARK: - Text Chat

    static func chat(_ prompt: String,
                     completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": "你是一个游戏自动化助手。只返回JSON，不要其他文字。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": 500
        ]

        var req = URLRequest(url: URL(string: "\(baseURL)/v1/chat/completions")!)
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
            else {
                completion(.failure(NSError(domain: "API", code: -1)))
                return
            }
            completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }

    // MARK: - Helpers

    private static func extractJSON(from text: String) -> String? {
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return nil
    }
}
