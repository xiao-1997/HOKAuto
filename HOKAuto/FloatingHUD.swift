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
        window?.windowLevel = .alert + 1
        window?.rootViewController = vc
        window?.isHidden = false
        window?.isUserInteractionEnabled = false
        window?.backgroundColor = .clear
    }

    func hide() {
        window?.isHidden = true
        window = nil
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
