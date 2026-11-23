import SwiftUI

/// Korte opstartanimatie: grijze ring met logo, de ring tekent zich wit op, het logo licht op, daarna weg (~1,4 s).
struct SplashView: View {
    @Binding var visible: Bool
    @State private var trim: CGFloat = 0
    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
                Circle().trim(from: 0, to: trim)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image("PulseLogo").resizable().scaledToFit().frame(width: 120)
                    .foregroundStyle(lit ? Color.white : Color.white.opacity(0.35))
                    .scaleEffect(lit ? 1 : 0.94)
            }
            .frame(width: 180, height: 180)
        }
        .onAppear {
            if reduceMotion { trim = 1; lit = true } else {
                withAnimation(.easeInOut(duration: 0.8)) { trim = 1 }
                withAnimation(.easeOut(duration: 0.4).delay(0.6)) { lit = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.3)) { visible = false }
            }
        }
        .allowsHitTesting(false)
    }
}
