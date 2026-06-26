import UIKit

/// DeepSeek V4 Pro 文本对话客户端
/// 用途：任务规划（高层目标→步骤序列）、异常恢复（步骤卡住时分析屏幕）
struct DeepSeekClient {
    static let baseURL = "https://api.deepseek.com/v1/chat/completions"
    static let apiKey = "sk-b9c5c60e28024ab7ac4ec39a17f3bee2"

    // MARK: - 文本对话（底层）

    static func chat(_ prompt: String,
                     systemPrompt: String = "你是一个精确的JSON生成器。",
                     maxTokens: Int = 200,
                     completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "model": "deepseek-v4-pro",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": maxTokens,
            "temperature": 0.1
        ]

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10

        Logger.log("DeepSeek: POST (maxTokens=\(maxTokens))")
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error {
                Logger.log("DeepSeek ERR: \(error.localizedDescription)")
                completion(.failure(error)); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String
            else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
                Logger.log("DeepSeek ERR: 解析失败 body=\(body.prefix(200))")
                completion(.failure(NSError(domain: "API", code: -1))); return
            }
            Logger.log("DeepSeek OK: \(content.prefix(120))")
            completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }

    // MARK: - 任务规划

    /// 将用户高层目标分解为 TaskStep JSON 序列
    static func planTask(_ goal: String, completion: @escaping (Result<[TaskStep], Error>) -> Void) {
        let systemPrompt = """
        你是王者荣耀自动化助手。将用户目标分解为操作步骤，返回纯JSON数组（不要markdown代码块）。
        每个步骤包含字段:
        - id: 步骤标识符(英文snake_case)
        - action: "click"|"input_text"|"wait"|"open_app"|"kill_app"|"wait_until"
        - target: 语义描述(中文,如"充值按钮")
        - coordLabel: 坐标缓存键(英文,如"recharge_btn")
        - maxRetries: 整数,默认3
        - waitAfter: 浮点数秒,默认1.5
        - verifyText: 验证关键词,步骤成功后屏幕上应出现的文字
        - optional: 布尔,此步骤失败是否可跳过,默认false

        常见流程参考：
        - 充值: 打开游戏→等待加载→关弹窗→登录→关弹窗→点充值入口→选金额→确认支付→输密码→完成→关游戏
        - 登录: 打开游戏→等待加载→关弹窗→点登录→关弹窗→完成
        - 签到: 打开游戏→等待加载→关弹窗→点活动/签到→关弹窗→领取→关弹窗→完成

        注意：每一步前系统会自动处理弹窗，所以步骤中不需要包含"关闭弹窗"步骤。
        游戏URL scheme: tencent1104466820://
        """

        chat(goal, systemPrompt: systemPrompt, maxTokens: 800) { result in
            switch result {
            case .success(let text):
                // 清理可能包裹的 markdown 代码块
                let jsonStr = text
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = jsonStr.data(using: .utf8),
                      let steps = try? JSONDecoder().decode([TaskStep].self, from: data) else {
                    Logger.log("DeepSeek planTask: JSON解析失败\n\(text.prefix(300))")
                    completion(.failure(NSError(domain: "Plan", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "步骤JSON解析失败"])))
                    return
                }
                Logger.log("DeepSeek planTask: 规划 \(steps.count) 个步骤")
                completion(.success(steps))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    // MARK: - 异常分析

    /// 步骤卡住时分析当前屏幕，给出下一步建议
    static func analyzeStuck(
        ocrTexts: [String],
        failedStep: TaskStep,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let systemPrompt = """
        你是王者荣耀自动化调试助手。当前自动化脚本执行卡住了，请根据屏幕上的文字内容分析原因并给出建议。
        返回格式(纯JSON,不要markdown):
        {"diagnosis":"问题诊断(中文,一句话)","suggestion":"建议操作(中文,一句话,如'点击返回按钮')","retry":"yes|no"}
        """

        let screenDesc = ocrTexts.joined(separator: " | ")
        let prompt = """
        执行步骤「\(failedStep.target)」失败(已重试\(failedStep.maxRetries)次)。
        验证关键词「\(failedStep.verifyText ?? "无")」未出现在屏幕上。

        当前屏幕OCR文字:
        \(screenDesc)

        请分析当前处于什么页面，应该采取什么操作。
        """

        chat(prompt, systemPrompt: systemPrompt, maxTokens: 200) { result in
            switch result {
            case .success(let text):
                Logger.log("DeepSeek analyzeStuck: \(text.prefix(200))")
                completion(.success(text))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }
}
