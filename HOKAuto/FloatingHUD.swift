import UIKit

/// 悬浮窗 - 显示操作步骤和识别状态
class FloatingHUD {
    static let shared = FloatingHUD()

    private var window: UIWindow?
    private var stepLabel: UILabel!
    private var statusLabel: UILabel!
    private var loadingDot: UIView!

    private init() {}

    func show() {
        guard window == nil else { return }

        let w = UIScreen.main.bounds.width
        let hudW: CGFloat = min(w - 40, 320)
        let hudH: CGFloat = 70

        let vc = UIViewController()
        vc.view.backgroundColor = .clear

        let container = UIView(frame: CGRect(x: (w - hudW)/2, y: 60, width: hudW, height: hudH))
        container.backgroundColor = UIColor(white: 0, alpha: 0.8)
        container.layer.cornerRadius = 12
        container.clipsToBounds = true

        // 步骤标签(顶部)
        stepLabel = UILabel(frame: CGRect(x: 12, y: 8, width: hudW - 24, height: 20))
        stepLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stepLabel.textColor = .white
        stepLabel.text = "就绪"
        container.addSubview(stepLabel)

        // 状态标签(底部)
        statusLabel = UILabel(frame: CGRect(x: 12, y: 32, width: hudW - 40, height: 28))
        statusLabel.font = .systemFont(ofSize: 15, weight: .bold)
        statusLabel.textColor = UIColor(red: 0, green: 1, blue: 0.53, alpha: 1)
        statusLabel.text = "等待操作..."
        container.addSubview(statusLabel)

        // 加载圆点
        loadingDot = UIView(frame: CGRect(x: hudW - 28, y: 36, width: 12, height: 12))
        loadingDot.backgroundColor = .clear
        loadingDot.layer.cornerRadius = 6
        container.addSubview(loadingDot)

        vc.view.addSubview(container)

        window = UIWindow(frame: UIScreen.main.bounds)
        // 最高层级确保在游戏上方
        window?.windowLevel = UIWindow.Level(rawValue: CGFloat.greatestFiniteMagnitude)
        window?.rootViewController = vc
        window?.isHidden = false
        window?.isUserInteractionEnabled = false
        window?.backgroundColor = .clear
        window?.makeKeyAndVisible()

        // 防止被其他窗口覆盖
        window?.isOpaque = false
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }

    // MARK: - 录制保存

    var onSave: ((String) -> Void)?
    private var saveField: UITextField?

    func showSaveDialog() {
        let alert = UIAlertController(title: "保存本次操作", message: "输入文件名", preferredStyle: .alert)
        alert.addTextField { t in t.placeholder = "如: hok_login" }
        alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            if let name = alert.textFields?.first?.text, !name.isEmpty {
                self.onSave?(name)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        window?.rootViewController?.present(alert, animated: true)
    }

    /// 设置步骤文本
    func setStep(_ text: String, color: UIColor = .white) {
        DispatchQueue.main.async {
            self.stepLabel?.text = text
            self.stepLabel?.textColor = color
        }
    }

    /// 设置状态
    func setStatus(_ text: String, color: UIColor? = nil) {
        DispatchQueue.main.async {
            self.statusLabel?.text = text
            if let c = color { self.statusLabel?.textColor = c }
        }
    }

    /// 识别结果
    func recognitionResult(_ type: String, name: String, success: Bool) {
        let prefix = success ? "✅" : "❌"
        let msg = type == "findImage" ? "本地匹配" : (type == "deepseek" ? "AI分析" : "人工")
        DispatchQueue.main.async {
            self.stepLabel?.text = "\(prefix) \(msg): \(name)"
            self.stepLabel?.textColor = success ?
                UIColor(red: 0, green: 1, blue: 0.53, alpha: 1) :
                UIColor(red: 1, green: 0.6, blue: 0, alpha: 1)
            // 3秒后恢复
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.stepLabel?.text = "检测中..."
                self.stepLabel?.textColor = .white
            }
        }
    }

    // MARK: - 任务进度

    /// 显示任务执行进度
    func showTaskProgress(_ progress: TaskProgress) {
        DispatchQueue.main.async {
            self.stepLabel?.text = "任务 [\(progress.stepIndex)/\(progress.totalSteps)] \(progress.stepDesc)"
            self.stepLabel?.textColor = .white
            self.statusLabel?.text = "⏳ \(progress.status)"
            self.statusLabel?.textColor = UIColor(red: 0, green: 1, blue: 0.53, alpha: 1)
        }
    }

    /// 显示任务结果
    func showTaskResult(_ result: TaskResult) {
        DispatchQueue.main.async {
            if result.success {
                self.stepLabel?.text = "✅ 任务完成"
                self.stepLabel?.textColor = UIColor(red: 0, green: 1, blue: 0.53, alpha: 1)
                self.statusLabel?.text = "\(result.completedSteps)/\(result.totalSteps)步成功"
            } else {
                self.stepLabel?.text = "❌ 任务失败"
                self.stepLabel?.textColor = UIColor(red: 1, green: 0.6, blue: 0, alpha: 1)
                self.statusLabel?.text = result.errorMessage ?? "未知错误"
            }
            // 3秒后恢复
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.stepLabel?.text = "守护中..."
                self.stepLabel?.textColor = .white
                self.statusLabel?.text = "等待指令"
            }
        }
    }

    /// 操作步骤进度
    enum StepState {
        case pending(String)
        case running(String)
        case success(String)
        case failed(String)
    }

    func showSteps(_ steps: [StepState]) {
        let texts = steps.map { s -> String in
            switch s {
            case .pending(let t): return "⏸ \(t)"
            case .running(let t): return "⏳ \(t)"
            case .success(let t): return "✅ \(t)"
            case .failed(let t): return "❌ \(t)"
            }
        }
        DispatchQueue.main.async {
            self.statusLabel?.text = texts.joined(separator: " → ")
            self.statusLabel?.font = .systemFont(ofSize: 11, weight: .medium)
        }
    }
}
