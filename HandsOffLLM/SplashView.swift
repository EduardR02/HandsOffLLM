import SwiftUI

struct SplashView: View {
    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            // App Logo/Title
            VStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue.gradient)

                Text("HandsOffLLM")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }

            Spacer()

            // Loading indicator
            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Spacer()
        }
    }
}

#Preview {
    SplashView()
}
