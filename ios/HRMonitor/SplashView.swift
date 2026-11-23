import SwiftUI

/// Korte opstartanimatie: ring en logo tekenen zich wit op vanuit zwart, daarna weg (~1,4 s).
struct SplashView: View {
    @Binding var visible: Bool
    @State private var trim: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                Circle().trim(from: 0, to: trim)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // Logo tekent zich van links naar rechts op, gelijk met de ring.
                Image("PulseLogo").resizable().scaledToFit().frame(width: 120)
                    .foregroundStyle(Color.white)
                    .mask(alignment: .leading) { Rectangle().scaleEffect(x: trim, y: 1, anchor: .leading) }
            }
            .frame(width: 180, height: 180)
        }
        .onAppear {
            if reduceMotion { trim = 1 } else { withAnimation(.easeInOut(duration: 0.9)) { trim = 1 } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.3)) { visible = false }
            }
        }
        .allowsHitTesting(false)
    }
}
