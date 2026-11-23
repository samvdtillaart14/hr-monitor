import SwiftUI

/// Opstartanimatie (~1,5 s): eerst schrijft "Pulse" zich van links naar rechts,
/// daarna tekent de hartslaglijn zich van links naar rechts; dan vervaagt alles.
struct SplashView: View {
    @Binding var visible: Bool
    @State private var word: CGFloat = 0
    @State private var line: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                layer("PulseWord", progress: word)
                layer("PulseLine", progress: line)
            }
            .frame(width: 200)
        }
        .onAppear {
            if reduceMotion { word = 1; line = 1 } else {
                withAnimation(.easeInOut(duration: 0.6)) { word = 1 }
                withAnimation(.easeInOut(duration: 0.55).delay(0.6)) { line = 1 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
                withAnimation(.easeOut(duration: 0.25)) { visible = false }
            }
        }
        .allowsHitTesting(false)
    }

    private func layer(_ name: String, progress: CGFloat) -> some View {
        Image(name).resizable().scaledToFit()
            .foregroundStyle(Color.white)
            .mask(alignment: .leading) { Rectangle().scaleEffect(x: progress, y: 1, anchor: .leading) }
    }
}
