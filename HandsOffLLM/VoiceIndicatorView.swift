import SwiftUI

struct VoiceIndicatorView: View {
    @Binding var isListening: Bool
    @Binding var isProcessing: Bool
    @Binding var isSpeaking: Bool

    // Animation states
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.6
    @State private var color: Color = .gray
    @State private var isPulsing: Bool = false // State to control repeating animation

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 150, height: 150) // Adjust size as needed
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                updateAnimationState(isInitial: true) // Set initial state without animation
            }
            .onChange(of: isListening) { _, newState in updateAnimationState() }
            .onChange(of: isProcessing) { _, newState in updateAnimationState() }
            .onChange(of: isSpeaking) { _, newState in updateAnimationState() }
            // Apply repeating animation conditionally based on isPulsing state
            .animation(isPulsing ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: scale)
            // Use .default animation for non-repeating changes to scale, color, opacity
            .animation(.easeInOut(duration: 0.3), value: color)
            .animation(.easeInOut(duration: 0.3), value: opacity)
    }

    // Added isInitial flag to prevent animation on first appearance
    private func updateAnimationState(isInitial: Bool = false) {
        let shouldPulse: Bool
        let targetScale: CGFloat
        let targetOpacity: Double
        let targetColor: Color

        if isListening {
            targetColor = .blue
            targetScale = 1.2
            targetOpacity = 0.8
            shouldPulse = true
        } else if isProcessing {
            targetColor = .gray
            targetScale = 1.0
            targetOpacity = 0.4
            shouldPulse = false // No pulse when processing
        } else if isSpeaking {
            targetColor = .green
            targetScale = 1.1
            targetOpacity = 0.7
            shouldPulse = true
        } else { // Idle
            targetColor = .gray
            targetScale = 1.0
            targetOpacity = 0.6
            shouldPulse = false
        }

        // Update target values (use withAnimation only if not initial)
         if isInitial {
             self.color = targetColor
             self.opacity = targetOpacity
             self.scale = targetScale // Set initial scale directly
             self.isPulsing = shouldPulse // Set initial pulsing state
         } else {
              // Use withAnimation for changes after initial appearance
              // Note: The .animation modifiers handle the animation itself now.
              // We just need to update the state values.
             self.color = targetColor
             self.opacity = targetOpacity
             self.isPulsing = shouldPulse // Update pulsing state *first*

             // If we are not pulsing, set scale directly to target.
             // If we *are* pulsing, the repeating animation modifier will handle the scale effect.
             if !shouldPulse {
                 self.scale = targetScale
             } else {
                 // Ensure scale starts from a reasonable value if pulsing starts
                 // Or let the animation modifier handle it from current value
                  // If scale is already large (e.g. was 1.2), maybe reset it?
                  if self.scale != targetScale {
                      // Optionally force scale to 1.0 before starting pulse?
                      // self.scale = 1.0 // This might cause a jump
                  }
                  // For pulsing, the targetScale (1.2 or 1.1) defines the *peak* of the pulse.
                  // The .repeatForever animation will oscillate around the base scale (implicitly 1.0?)
                  // Let's try letting the animation modifier handle the scale oscillation directly when isPulsing is true.
                  // We might need to adjust the base scale value if it doesn't reset nicely.
                  // Let's explicitly set the scale target when pulsing starts/continues
                  self.scale = targetScale
             }
         }
    }
}

// Preview provider for VoiceIndicatorView
#Preview {
    // Example states for previewing
    VoiceIndicatorView(isListening: .constant(false), isProcessing: .constant(true), isSpeaking: .constant(false))
}

#Preview("Listening") {
    VoiceIndicatorView(isListening: .constant(true), isProcessing: .constant(false), isSpeaking: .constant(false))
}

#Preview("Speaking") {
    VoiceIndicatorView(isListening: .constant(false), isProcessing: .constant(false), isSpeaking: .constant(true))
}

#Preview("Idle") {
    VoiceIndicatorView(isListening: .constant(false), isProcessing: .constant(false), isSpeaking: .constant(false))
} 