import SwiftUI

struct ContentView: View {
    @State private var status = "就绪"
    @State private var logs = ""
    @State private var isRunning = false
    @State private var isExecutingTask = false
    @State private var macros: [String] = []
    @State private var saveName = ""
    @State private var taskText = ""
    @State private var showCoordEditor = false
    @State private var coordJSON = CoordCache.shared.exportJSON()
    private let engine = AutomationEngine()

    // 快捷指令
    private let quickCommands = [
        "充值60点券",
        "充值475点券",
        "登录账号",
        "每日签到",
        "打开商城",
        "领取奖励",
    ]

    var body: some View {
        ZStack {
            Color(hex: "0D0D1A").edgesIgnoringSafeArea(.all)

            ScrollView {
                VStack(spacing: 12) {
                    // 状态卡片
                    statusCard

                    // 快捷指令
                    quickCommandBar

                    // 任务输入
                    taskInputBar

                    // 日志
                    logArea

                    // 启动/停止按钮
                    if isRunning {
                        Button(action: stopEngine) {
                            HStack {
                                if isExecutingTask {
                                    Image(systemName: "hourglass")
                                    Text("⏹ 停止 (任务执行中)")
                                } else {
                                    Text("⏹ 停止")
                                }
                            }
                            .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .background(Color.red).cornerRadius(14)
                        }
                    } else {
                        Button(action: startEngine) {
                            Text("🚀 启动自动化")
                                .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 54)
                                .background(Color(hex: "667eea")).cornerRadius(14)
                        }
                    }

                    // 保存 + 坐标管理
                    if !isRunning {
                        macroSection
                    }

                    // 已保存宏列表
                    if !macros.isEmpty {
                        savedMacrosList
                    }
                }
                .padding(16)
            }
        }
        .onAppear { refreshMacros(); coordJSON = CoordCache.shared.exportJSON() }
        .sheet(isPresented: $showCoordEditor) {
            coordEditorView
        }
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(spacing: 12) {
            Image(systemName: isExecutingTask
                  ? "arrow.triangle.2.circlepath"
                  : (isRunning ? "shield.checkered" : "checkmark.circle.fill"))
                .font(.system(size: 48)).foregroundColor(.white)
            Text(status).font(.system(size: 24, weight: .bold)).foregroundColor(.white)
            if isExecutingTask {
                Text("任务模式").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity).padding(32)
        .background(
            LinearGradient(
                gradient: Gradient(colors: isExecutingTask
                    ? [Color(hex: "f093fb"), Color(hex: "f5576c")]
                    : [Color(hex: "667eea"), Color(hex: "764ba2")]),
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        ).cornerRadius(16)
    }

    // MARK: - 快捷指令

    private var quickCommandBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickCommands, id: \.self) { cmd in
                    Button(action: { sendQuickCommand(cmd) }) {
                        Text(cmd)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "00FF88"))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.white.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "00FF88").opacity(0.3)))
                            .cornerRadius(8)
                    }
                }
            }
        }
    }

    // MARK: - 任务输入

    private var taskInputBar: some View {
        HStack(spacing: 8) {
            TextField("输入任务，如: 充值475点券，密码123456", text: $taskText)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color(hex: "1A1A2E"))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1)))

            Button(action: executeTask) {
                Text("执行")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(
                        taskText.isEmpty ? Color.gray : Color(hex: "00CC66")
                    )
                    .cornerRadius(10)
            }
            .disabled(taskText.isEmpty || isExecutingTask)
        }
    }

    // MARK: - 日志

    private var logArea: some View {
        ScrollView {
            Text(logs.isEmpty ? "输入任务后点击执行..." : logs)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "00FF88"))
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(maxHeight: 180)
        .background(Color(hex: "1A1A2E")).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
    }

    // MARK: - 宏管理

    private var macroSection: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("文件名", text: $saveName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                Button("💾 保存操作") {
                    if !saveName.isEmpty { _ = engine.saveMacro(name: saveName); saveName = ""; refreshMacros() }
                }
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "00FF88"))
            }
            Button(action: { showCoordEditor = true }) {
                HStack {
                    Image(systemName: "map")
                    Text("管理预设坐标 (\(CoordCache.shared.exportJSON().count)条)")
                        .font(.system(size: 13))
                }
                .foregroundColor(Color(hex: "FFD700"))
            }
        }
    }

    // MARK: - 已保存宏

    private var savedMacrosList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📋 已保存的操作").foregroundColor(.white).font(.caption)
            ForEach(macros, id: \.self) { name in
                HStack {
                    Text(name).foregroundColor(.white).font(.system(size: 14))
                    Spacer()
                    Button("▶️") { engine.replayMacro(name: name) }
                        .font(.system(size: 14))
                    Button("🗑") { MacroRecorder.delete(name); refreshMacros() }
                        .font(.system(size: 14))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.white.opacity(0.1)).cornerRadius(8)
            }
        }
    }

    // MARK: - 坐标编辑器

    private var coordEditorView: some View {
        NavigationView {
            VStack {
                Text("每行一个坐标: label,x,y,source\n例: 关闭弹窗,1896,124,manual")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.top, 8)

                TextEditor(text: $coordJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "00FF88"))
                    .background(Color(hex: "1A1A2E"))
                    .cornerRadius(8)
                    .padding(.horizontal, 8)

                HStack {
                    Button("导入") {
                        CoordCache.shared.importFromUser(coordJSON)
                        coordJSON = CoordCache.shared.exportJSON()
                    }
                    .foregroundColor(Color(hex: "00FF88"))
                    .padding()
                }
            }
            .navigationTitle("预设坐标管理")
            .background(Color(hex: "0D0D1A"))
        }
    }

    // MARK: - Actions

    private func startEngine() {
        engine.onUpdate = {
            status = engine.status
            logs = engine.logs
            isRunning = engine.isRunning
            isExecutingTask = engine.isExecutingTask
        }
        engine.run()
        FloatingHUD.shared.onSave = { name in _ = engine.saveMacro(name: name); refreshMacros() }
    }

    private func stopEngine() {
        if engine.isExecutingTask { engine.cancelTask() }
        engine.isRunning = false
        engine.status = "已停止"
        logs = engine.logs
        isRunning = false
        isExecutingTask = false
    }

    private func executeTask() {
        guard !taskText.isEmpty else { return }
        let cmd = taskText.trimmingCharacters(in: .whitespaces)
        engine.runTask(cmd)
        taskText = ""
        logs = ">>> \(cmd)\n" + logs
    }

    private func sendQuickCommand(_ cmd: String) {
        taskText = cmd
        executeTask()
    }

    private func refreshMacros() {
        macros = MacroRecorder.list()
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
