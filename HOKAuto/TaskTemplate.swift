import Foundation

/// 单个任务步骤
struct TaskStep: Codable, Equatable {
    let id: String                  // "enter_shop"
    let action: String              // "click" | "input_text" | "wait" | "open_app" | "kill_app" | "wait_until"
    let target: String              // 语义描述: "充值入口", "475点券选项", "确认支付"
    let coordLabel: String          // CoordCache 缓存键
    let maxRetries: Int             // 最大重试次数
    let waitAfter: TimeInterval     // 点击后等待秒数
    let verifyText: String?         // 验证关键词（OCR检测到此词=步骤成功）
    let optional: Bool              // 步骤失败是否可跳过

    init(id: String, action: String, target: String, coordLabel: String,
         maxRetries: Int = 3, waitAfter: TimeInterval = 1.5,
         verifyText: String? = nil, optional: Bool = false) {
        self.id = id
        self.action = action
        self.target = target
        self.coordLabel = coordLabel
        self.maxRetries = maxRetries
        self.waitAfter = waitAfter
        self.verifyText = verifyText
        self.optional = optional
    }
}

/// 任务模板库：预定义常见任务的步骤序列
struct TaskTemplate {
    /// 所有预置模板
    static let builtIn: [String: [TaskStep]] = [
        "充值点券": rechargeTemplate(amount: nil),
        "登录账号": loginTemplate,
        "每日签到": dailyCheckinTemplate,
        "打开商城": openShopTemplate,
    ]

    /// 提取用户指令中的金额参数
    static func extractAmount(from goal: String) -> String? {
        let pattern = "\\d+"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)) else {
            return nil
        }
        return String(goal[Range(match.range, in: goal)!])
    }

    /// 提取密码参数
    static func extractPassword(from goal: String) -> String? {
        let patterns = ["密码(\\S+)", "密码[：:](\\S+)"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)) else {
                continue
            }
            let range = match.range(at: 1)
            return String(goal[Range(range, in: goal)!])
        }
        return nil
    }

    /// 匹配预置模板
    static func match(goal: String) -> (name: String, steps: [TaskStep])? {
        let lower = goal.lowercased()

        if lower.contains("充值") || lower.contains("点券") {
            let amount = extractAmount(from: goal)
            return ("充值点券", rechargeTemplate(amount: amount))
        }
        if lower.contains("登录") {
            return ("登录账号", loginTemplate)
        }
        if lower.contains("签到") || lower.contains("每日") {
            return ("每日签到", dailyCheckinTemplate)
        }
        if lower.contains("商城") || lower.contains("商店") {
            return ("打开商城", openShopTemplate)
        }
        return nil
    }

    // MARK: - 模板定义

    private static func rechargeTemplate(amount: String?) -> [TaskStep] {
        let amt = amount ?? "{amount}"
        return [
            TaskStep(id: "open_game", action: "open_app",
                     target: "王者荣耀", coordLabel: "app_hok",
                     maxRetries: 2, waitAfter: 2, verifyText: nil),

            TaskStep(id: "wait_loaded", action: "wait_until",
                     target: "游戏大厅", coordLabel: "game_loaded",
                     maxRetries: 30, waitAfter: 2,
                     verifyText: "开始游戏,商城,英雄,备战"),

            TaskStep(id: "click_recharge_entry", action: "click",
                     target: "充值/商城入口", coordLabel: "recharge_entry",
                     maxRetries: 4, waitAfter: 2, verifyText: "点券,充值"),

            TaskStep(id: "select_amount", action: "click",
                     target: "\(amt)点券选项", coordLabel: "amount_\(amt)",
                     maxRetries: 4, waitAfter: 1, verifyText: "\(amt)"),

            TaskStep(id: "confirm_pay", action: "click",
                     target: "确认支付", coordLabel: "confirm_pay",
                     maxRetries: 3, waitAfter: 3, verifyText: "支付,密码"),

            TaskStep(id: "input_password", action: "input_text",
                     target: "输入密码", coordLabel: "password_input",
                     maxRetries: 2, waitAfter: 2, verifyText: "支付成功,充值成功",
                     optional: true),

            TaskStep(id: "close_game", action: "kill_app",
                     target: "关闭王者荣耀", coordLabel: "app_hok",
                     maxRetries: 1, waitAfter: 1, verifyText: nil, optional: true),
        ]
    }

    private static let loginTemplate: [TaskStep] = [
        TaskStep(id: "open_game", action: "open_app",
                 target: "王者荣耀", coordLabel: "app_hok",
                 maxRetries: 2, waitAfter: 2),

        TaskStep(id: "wait_loaded", action: "wait_until",
                 target: "游戏加载", coordLabel: "game_loaded",
                 maxRetries: 30, waitAfter: 2,
                 verifyText: "开始游戏,登录,微信,QQ"),

        TaskStep(id: "click_login", action: "click",
                 target: "登录按钮", coordLabel: "login_btn",
                 maxRetries: 4, waitAfter: 3,
                 verifyText: "开始游戏,大厅,商城"),
    ]

    private static let dailyCheckinTemplate: [TaskStep] = [
        TaskStep(id: "open_game", action: "open_app",
                 target: "王者荣耀", coordLabel: "app_hok",
                 maxRetries: 2, waitAfter: 2),

        TaskStep(id: "wait_loaded", action: "wait_until",
                 target: "游戏大厅", coordLabel: "game_loaded",
                 maxRetries: 30, waitAfter: 2,
                 verifyText: "开始游戏,商城,英雄"),

        TaskStep(id: "login", action: "click",
                 target: "登录按钮", coordLabel: "login_btn",
                 maxRetries: 3, waitAfter: 3,
                 verifyText: "开始游戏,大厅"),

        TaskStep(id: "click_event", action: "click",
                 target: "活动/签到入口", coordLabel: "event_entry",
                 maxRetries: 4, waitAfter: 2, verifyText: "签到,每日"),

        TaskStep(id: "click_checkin", action: "click",
                 target: "签到按钮", coordLabel: "checkin_btn",
                 maxRetries: 3, waitAfter: 1.5, verifyText: "已签到,领取"),

        TaskStep(id: "collect_reward", action: "click",
                 target: "领取奖励", coordLabel: "collect_reward",
                 maxRetries: 3, waitAfter: 1, verifyText: nil, optional: true),
    ]

    private static let openShopTemplate: [TaskStep] = [
        TaskStep(id: "open_game", action: "open_app",
                 target: "王者荣耀", coordLabel: "app_hok",
                 maxRetries: 2, waitAfter: 2),

        TaskStep(id: "wait_loaded", action: "wait_until",
                 target: "游戏大厅", coordLabel: "game_loaded",
                 maxRetries: 30, waitAfter: 2,
                 verifyText: "开始游戏,商城,英雄"),

        TaskStep(id: "click_shop", action: "click",
                 target: "商城入口", coordLabel: "shop_entry",
                 maxRetries: 4, waitAfter: 2, verifyText: "商城,商店"),
    ]
}
