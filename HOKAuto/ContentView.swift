import SwiftUI

struct ContentView: View {
    @State private var status = "就绪"
    @State private var logs = ""
    @State private var isRunning = false
    @State private var macros: [String] = []
    @State private var saveName = ""
    private let engine = AutomationEngine()

    var body: some View {
        ZStack {
            Color(hex: "0D0D1A").edgesIgnoringSafeArea(.all)

            VStack(spacing: 16) {
                // 状态卡片
                VStack(spacing: 12) {
                    Image(systemName: isRunning ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                        .font(.system(size: 48)).foregroundColor(.white)
                    Text(status).font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                }
                .frame(maxWidth: .infinity).padding(32)
                .background(LinearGradient(gradient: Gradient(colors: [Color(hex: "667eea"), Color(hex: "764ba2")]),
                    startPoint: .topLeading, endPoint: .bottomTrailing)).cornerRadius(16)

                // 日志
                ScrollView {
                    Text(logs.isEmpty ? "点击启动..." : logs)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(hex: "00FF88"))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(maxHeight: 200)
                .background(Color(hex: "1A1A2E")).cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))

                // 启动按钮
                Button(action: startEngine) {
                    Text(isRunning ? "执行中..." : "🚀 启动自动化")
                        .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(isRunning ? Color.gray : Color(hex: "667eea")).cornerRadius(14)
                }.disabled(isRunning)

                // 保存按钮
                if !isRunning {
                    HStack {
                        TextField("文件名", text: $saveName)
                            .textFieldStyle(.roundedBorder)
                        Button("💾 保存本次操作") {
                            if !saveName.isEmpty { _ = engine.saveMacro(name: saveName); saveName = ""; refreshMacros() }
                        }
                        .foregroundColor(Color(hex: "00FF88"))
                    }
                }

                // 已保存宏列表
                if !macros.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("📋 已保存的操作").foregroundColor(.white).font(.caption)
                        ForEach(macros, id: \.self) { name in
                            HStack {
                                Text(name).foregroundColor(.white)
                                Spacer()
                                Button("▶️") { engine.replayMacro(name: name) }
                                Button("🗑") { MacroRecorder.delete(name); refreshMacros() }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.white.opacity(0.1)).cornerRadius(8)
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear { refreshMacros() }
    }

    private func startEngine() {
        engine.onUpdate = { status = engine.status; logs = engine.logs; isRunning = engine.isRunning }
        engine.run()
        FloatingHUD.shared.onSave = { name in
            _ = engine.saveMacro(name: name)
            refreshMacros()
        }
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
