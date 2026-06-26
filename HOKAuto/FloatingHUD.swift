import UIKit

/// 悬浮窗 - 显示状态 + 停止/停止录制按钮
class FloatingHUD {
    static let shared = FloatingHUD()

    private var window: UIWindow?
    private var stepLabel: UILabel!
    private var statusLabel: UILabel!
    private var stopBtn: UIButton!
    private var stopRecordBtn: UIButton!

    /// 按钮回调
    var onStop: (() -> Void)?
    var onStopRecord: (() -> Void)?

    private init() {}

    func show() {
        guard window == nil else { return }

        let screenW = UIScreen.main.bounds.width
        let hudW: CGFloat = min(screenW - 40, 300)
        let hudH: CGFloat = 110

        let vc = UIViewController()
        vc.view.backgroundColor = .clear

        let container = UIView(frame: CGRect(x: (screenW - hudW)/2, y: 50, width: hudW, height: hudH))
        container.backgroundColor = UIColor(white: 0, alpha: 0.82)
        container.layer.cornerRadius = 14
        container.clipsToBounds = true

        // 步骤标签(顶部)
        stepLabel = UILabel(frame: CGRect(x: 12, y: 10, width: hudW - 24, height: 18))
        stepLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stepLabel.textColor = UIColor(white: 1, alpha: 0.7)
        stepLabel.text = "就绪"
        container.addSubview(stepLabel)

        // 状态标签(中间)
        statusLabel = UILabel(frame: CGRect(x: 12, y: 30, width: hudW - 24, height: 24))
        statusLabel.font = .systemFont(ofSize: 15, weight: .bold)
        statusLabel.textColor = UIColor(red: 0, green: 1, blue: 0.53, alpha: 1)
        statusLabel.text = "等待..."
        container.addSubview(statusLabel)

        // 按钮行
        let btnY: CGFloat = 60
        let btnH: CGFloat = 36
        let btnW = (hudW - 36) / 2

        // 停止录制按钮（左）
        stopRecordBtn = UIButton(frame: CGRect(x: 12, y: btnY, width: btnW, height: btnH))
        stopRecordBtn.setTitle("🔴 停止录制", for: .normal)
        stopRecordBtn.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        stopRecordBtn.setTitleColor(.white, for: .normal)
        stopRecordBtn.backgroundColor = UIColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 0.8)
        stopRecordBtn.layer.cornerRadius = 8
        stopRecordBtn.addTarget(self, action: #selector(tapStopRecord), for: .touchUpInside)
        container.addSubview(stopRecordBtn)

        // 停止按钮（右）
        stopBtn = UIButton(frame: CGRect(x: 24 + btnW, y: btnY, width: btnW, height: btnH))
        stopBtn.setTitle("⏹ 停止", for: .normal)
        stopBtn.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        stopBtn.setTitleColor(.white, for: .normal)
        stopBtn.backgroundColor = UIColor(white: 0.3, alpha: 0.8)
        stopBtn.layer.cornerRadius = 8
        stopBtn.addTarget(self, action: #selector(tapStop), for: .touchUpInside)
        container.addSubview(stopBtn)

        vc.view.addSubview(container)

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.windowLevel = UIWindow.Level(rawValue: CGFloat.greatestFiniteMagnitude)
        window?.rootViewController = vc
        window?.isHidden = false
        window?.isUserInteractionEnabled = true  // 可交互
        window?.backgroundColor = .clear
        window?.makeKeyAndVisible()
        window?.isOpaque = false
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }

    // MARK: - 按钮动作

    @objc private func tapStop() {
        onStop?()
    }

    @objc private func tapStopRecord() {
        onStopRecord?()
        stopRecordBtn.setTitle("🔴 已停", for: .normal)
        stopRecordBtn.alpha = 0.5
        stopRecordBtn.isEnabled = false
        // 3秒恢复
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.stopRecordBtn.setTitle("🔴 停止录制", for: .normal)
            self?.stopRecordBtn.alpha = 1.0
            self?.stopRecordBtn.isEnabled = true
        }
    }

    // MARK: - 录制保存

    var onSave: ((String) -> Void)?

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.stepLabel?.text = "检测中..."
                self.stepLabel?.textColor = .white
            }
        }
    }

    // MARK: - 任务进度

    func showTaskProgress(_ progress: TaskProgress) {
        DispatchQueue.main.async {
            self.stepLabel?.text = "任务 [\(progress.stepIndex)/\(progress.totalSteps)] \(progress.stepDesc)"
            self.stepLabel?.textColor = .white
            self.statusLabel?.text = "⏳ \(progress.status)"
            self.statusLabel?.textColor = UIColor(red: 0, green: 1, blue: 0.53, alpha: 1)
        }
    }

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
