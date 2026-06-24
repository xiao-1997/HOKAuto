import SwiftUI

struct ContentView: View {
    @State private var status = "就绪"
    @State private var logs = ""
    @State private var isRunning = false
    private let engine = AutomationEngine()

    var body: some View {
        ZStack {
            Color(hex: "0D0D1A").ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: isRunning
                        ? "arrow.triangle.2.circlepath"
                        : "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white)

                    Text(status)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "667eea"), Color(hex: "764ba2")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(16)

                ScrollView {
                    Text(logs.isEmpty ? "点击启动..." : logs)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(hex: "00FF88"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 300)
                .background(Color(hex: "1A1A2E"))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)))

                Button(action: {
                    engine.onUpdate = {
                        status = engine.status
                        logs = engine.logs
                        isRunning = engine.isRunning
                    }
                    engine.run()
                }) {
                    Text(isRunning ? "执行中..." : "🚀 启动自动化")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(isRunning ? Color.gray : Color(hex: "667eea"))
                        .cornerRadius(14)
                }
                .disabled(isRunning)
            }
            .padding(24)
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
