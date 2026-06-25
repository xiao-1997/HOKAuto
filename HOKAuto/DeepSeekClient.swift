import UIKit

/// DeepSeek API 视觉识别客户端
struct DeepSeekClient {
    static let baseURL = "https://api.deepseek.com"
    static var apiKey = "" // 在 App 设置中配置

    /// 分析截图，识别按钮和文字
    static func analyzeScreenshot(_ image: UIImage, prompt: String,
                                  completion: @escaping (Result<String, Error>) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            completion(.failure(NSError(domain: "ImageError", code: -1)))
            return
        }
        let base64 = imageData.base64EncodedString()

        let fullPrompt = """
        你是一个iOS游戏自动化助手。分析这张王者荣耀游戏截图(1242x2208横屏)：
        1. 列出所有可见的按钮（名称+坐标x,y）
        2. 列出弹窗和关闭按钮位置
        3. 列出"暂不参与"、"取消"、"确定"、"返回"按钮位置
        \(prompt)
        返回JSON格式: {"buttons":[{"name":"","x":0,"y":0}],"popups":[{"text":"","close_x":0,"close_y":0}]}
        """

        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": "你是游戏自动化助手，分析截图返回按钮坐标JSON"],
                ["role": "user", "content": [
                    ["type": "text", "text": fullPrompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + base64]]
                ]]
            ],
            "temperature": 0.1,
            "max_tokens": 1000
        ]

        var req = URLRequest(url: URL(string: "\(baseURL)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

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
            completion(.success(content))
        }.resume()
    }

    /// 提取按钮坐标
    static func parseButtons(from text: String) -> [(name: String, x: Float, y: Float)] {
        var results: [(name: String, x: Float, y: Float)] = []
        guard let data = extractJSON(from: text)?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buttons = json["buttons"] as? [[String: Any]]
        else { return results }

        for btn in buttons {
            if let name = btn["name"] as? String,
               let x = btn["x"] as? Double,
               let y = btn["y"] as? Double {
                results.append((name, Float(x), Float(y)))
            }
        }
        return results
    }

    private static func extractJSON(from text: String) -> String? {
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return nil
    }
}
