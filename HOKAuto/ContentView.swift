import SwiftUI

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

struct ContentView: View {
    @StateObject private var engine = AutomationEngine()

    var body: some View {
        ZStack {
            Color(hex: "0D0D1A").ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: engine.isRunning
                        ? "arrow.triangle.2.circlepath"
                        : "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white)
                        .symbolEffect(.rotate, value: engine.isRunning)

                    Text(engine.status)
                        .font(.title2).bold()
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

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(engine.logs.isEmpty ? "点击启动..." : engine.logs)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Color(hex: "00FF88"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("log")
                    }
                    .frame(maxHeight: 300)
                    .background(Color(hex: "1A1A2E"))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)))
                    .onChange(of: engine.logs) { _ in
                        withAnimation { proxy.scrollTo("log", anchor: .bottom) }
                    }
                }

                Button(action: engine.run) {
                    HStack(spacing: 10) {
                        if engine.isRunning {
                            ProgressView().tint(.white)
                            Text("执行中...")
                        } else {
                            Text("🚀 启动自动化")
                        }
                    }
                    .font(.title3).bold()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(engine.isRunning ? Color.gray : Color(hex: "667eea"))
                    .cornerRadius(14)
                }
                .disabled(engine.isRunning)
            }
            .padding(24)
        }
    }
}
