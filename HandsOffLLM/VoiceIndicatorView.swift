import SwiftUI

// No need for import YourAppModuleName if ViewModelState is top-level

struct VoiceIndicatorView: View {
    // Use the top-level ViewModelState
    @Binding var state: ViewModelState
    @Binding var audioLevel: Float // User mic level (dBFS)
    @Binding var ttsLevel: Float   // TTS output level (normalized 0-1)
    
    // Constants
    private let baseScale: CGFloat = 1.0
    // Scale multipliers for mic input and TTS output - Increased for more reaction
    private let listeningScaleMultiplier: CGFloat = 0.8 // Increased from 0.6
    private let speakingScaleMultiplier: CGFloat = 0.5 // Increased from 0.2
    private let minDB: Float = -50.0 // Assuming audioLevel is dBFS
    private let maxDB: Float = 0.0
    // Assuming ttsLevel is normalized 0-1
    private let minTTSLevel: Float = 0.0
    private let maxTTSLevel: Float = 1.0
    
    private let animationResponse: Double = 0.3
    private let animationDamping: Double = 0.4 // Reduced damping for bouncier scale
    
    // --- Dreamier Color Palettes ---
    // Updated gradients to accept an angle
    private func idleGradient(angle: Angle) -> AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                Color.gray.opacity(0.2), // Slightly increased base opacity
                Color.gray.opacity(0.4),
                Color.white.opacity(0.2),
                Color.gray.opacity(0.4),
                Color.gray.opacity(0.2)
            ]),
            center: .center,
            angle: angle
        )
    }
    
    // Listening gradient remains largely the same, maybe slightly brighter highlights
    private func listeningGradient(normalizedLevel: CGFloat, angle: Angle) -> AngularGradient {
        let baseBlue = Color(hue: 0.6, saturation: 0.7, brightness: 0.9) // Slightly richer
        let highlightPurple = Color(hue: 0.75, saturation: 0.8, brightness: 1.0) // Brighter highlight
        let dynamicOpacity = 0.6 + (normalizedLevel * 0.4) // Start slightly more opaque
        let dynamicBrightnessScale = 1.0 + (normalizedLevel * 0.20) // Slightly more brightness reaction
        
        // Inline brightness adjustment for simplicity here
        func adjustBrightness(_ color: Color, scale: CGFloat) -> Color {
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return Color(hue: hue, saturation: saturation, brightness: min(1.0, brightness * scale), opacity: alpha)
        }
        
        return AngularGradient(
            gradient: Gradient(colors: [
                baseBlue.opacity(dynamicOpacity * 0.8),
                adjustBrightness(highlightPurple, scale: dynamicBrightnessScale * 1.1).opacity(dynamicOpacity), // More pop
                baseBlue.opacity(dynamicOpacity * 0.7),
                adjustBrightness(highlightPurple, scale: dynamicBrightnessScale * 1.2).opacity(dynamicOpacity * 0.9), // More pop
                baseBlue.opacity(dynamicOpacity * 0.8),
            ]),
            center: .center,
            angle: angle
        )
    }
    
    // Processing gradient - add a subtle inner shimmer maybe? Using Radial for variation.
    private func processingGradient(angle: Angle) -> RadialGradient {
        RadialGradient(
            gradient: Gradient(colors: [
                Color.cyan.opacity(0.6), // Center color
                Color.blue.opacity(0.4),
                Color.purple.opacity(0.5),
                Color.blue.opacity(0.3) // Outer edge
            ]),
            center: .center,
            startRadius: 5, // Small start radius for the cyan center
            endRadius: 100 // End radius covering the circle size
        )
        // Note: We lose the direct angle rotation here with RadialGradient.
        // Could combine or overlay with an angular one if rotation is essential for processing.
        // Let's try without rotation for processing for variety.
    }
    
    
    private func speakingGradient(angle: Angle) -> AngularGradient {
        // Slightly softer, warmer speaking colors
        AngularGradient(
            gradient: Gradient(colors: [
                Color(hue: 0.98, saturation: 0.7, brightness: 1.0).opacity(0.7), // Pink
                Color(hue: 0.08, saturation: 0.6, brightness: 1.0).opacity(0.8), // Orange
                Color(hue: 0.12, saturation: 0.7, brightness: 1.0).opacity(0.7), // Gold/Yellowish
                Color(hue: 0.08, saturation: 0.6, brightness: 1.0).opacity(0.8), // Orange
                Color(hue: 0.98, saturation: 0.7, brightness: 1.0).opacity(0.7), // Pink
            ]),
            center: .center,
            angle: angle
        )
    }
    
    // StateProperties holds only the common dynamic values
    private struct StateProperties: Equatable {
        let scale: CGFloat
        let blurRadius: CGFloat
        let angle: Angle // Angle for rotation (used by Angular gradients)
        let identifier: Int // Corresponds to ViewModelState hashValue or explicit mapping
        let normalizedMicLevel: CGFloat
        let normalizedTTSLevel: CGFloat
    }
    
    // Calculate the state properties based on the ViewModelState
    private func calculateStateProperties(currentAngle: Angle) -> StateProperties {
        let micLevelNormalized = CGFloat(max(0, min(1, (audioLevel - minDB) / (maxDB - minDB))))
        let ttsLevelNormalized = CGFloat(max(0, min(1, (ttsLevel - minTTSLevel) / (maxTTSLevel - minTTSLevel))))
        
        let micExponent: CGFloat = 1.5
        let curvedMicLevel = pow(micLevelNormalized, micExponent)
        let curvedTTSLevel = ttsLevelNormalized
        
        let rotationSpeedMultiplier: Double
        let stateIdentifier: Int
        let calculatedScale: CGFloat
        let calculatedBlur: CGFloat
        
        // Determine visuals based on the state enum
        switch state {
        case .speakingTTS:
            rotationSpeedMultiplier = 2.5
            stateIdentifier = 3 // Matches gradientView case
            calculatedScale = baseScale + (curvedTTSLevel * speakingScaleMultiplier)
            calculatedBlur = 3 + (curvedTTSLevel * 3)
        case .listening:
            rotationSpeedMultiplier = 3.0
            stateIdentifier = 1 // Matches gradientView case
            calculatedScale = baseScale + (curvedMicLevel * listeningScaleMultiplier)
            calculatedBlur = 2 + (curvedMicLevel * 4)
        case .processingLLM:
            rotationSpeedMultiplier = 0 // No rotation for radial
            stateIdentifier = 2 // Matches gradientView case
            calculatedScale = baseScale * 0.9 // Slightly smaller for processing
            calculatedBlur = 15 // More blur for processing state
        case .idle:
            rotationSpeedMultiplier = 0.5 // Slow rotation
            stateIdentifier = 0 // Matches gradientView case
            calculatedScale = baseScale
            calculatedBlur = 2
        }
        
        let dynamicAngle = currentAngle * rotationSpeedMultiplier
        
        return StateProperties(
            scale: calculatedScale,
            blurRadius: calculatedBlur,
            angle: dynamicAngle,
            identifier: stateIdentifier,
            normalizedMicLevel: curvedMicLevel,
            normalizedTTSLevel: curvedTTSLevel
        )
    }
    
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let baseRotationSpeed: Double = 70
            let currentAngle = Angle.degrees(fmod(time * baseRotationSpeed, 360))
            
            let determinedState = calculateStateProperties(currentAngle: currentAngle)
            
            ZStack {
                // Background Glow Layer
                gradientView(for: determinedState) // Use helper
                    .frame(width: 200, height: 200)
                    .scaleEffect(determinedState.scale * 1.05)
                    .blur(radius: determinedState.blurRadius + 25)
                    .opacity(0.6)
                
                // Main Foreground Layer
                gradientView(for: determinedState) // Use helper
                    .frame(width: 200, height: 200)
                    .scaleEffect(determinedState.scale)
                    .blur(radius: determinedState.blurRadius)
                
            }
            .shadow(color: .black.opacity(0.4), radius: determinedState.blurRadius > 2 ? 20 : 10, x: 0, y: 10)
            .animation(.spring(response: animationResponse * 0.8, dampingFraction: animationDamping), value: determinedState.identifier) // Animate based on state identifier
            .animation(.spring(response: animationResponse, dampingFraction: animationDamping), value: determinedState.scale)
            .animation(.spring(response: animationResponse, dampingFraction: animationDamping), value: determinedState.blurRadius)
        }
    }
    
    // Helper function to return the correctly filled Circle view based on state identifier
    @ViewBuilder
    private func gradientView(for stateProps: StateProperties) -> some View {
        let shape = Circle()
        switch stateProps.identifier {
        case 0: // Idle
            shape.fill(idleGradient(angle: stateProps.angle))
        case 1: // Listening
            shape.fill(listeningGradient(normalizedLevel: stateProps.normalizedMicLevel, angle: stateProps.angle))
        case 2: // Processing
            shape.fill(processingGradient(angle: stateProps.angle)) // Uses Radial, angle ignored internally
        case 3: // Speaking
            shape.fill(speakingGradient(angle: stateProps.angle))
        default:
            shape.fill(idleGradient(angle: stateProps.angle))
        }
    }
}

// --- Previews ---
// Update previews to use the state enum explicitly

#Preview("Idle") {
    VoiceIndicatorView(
        state: .constant(ViewModelState.idle), // Explicit type
        audioLevel: .constant(-50.0),
        ttsLevel: .constant(0.0)
    )
    .preferredColorScheme(.dark)
}

#Preview("Listening Low") {
    VoiceIndicatorView(
        state: .constant(ViewModelState.listening), // Explicit type
        audioLevel: .constant(-30.0),
        ttsLevel: .constant(0.0)
    )
    .preferredColorScheme(.dark)
}

#Preview("Listening High") {
    VoiceIndicatorView(
        state: .constant(ViewModelState.listening), // Explicit type
        audioLevel: .constant(-5.0),
        ttsLevel: .constant(0.0)
    )
    .preferredColorScheme(.dark)
}

#Preview("Processing") {
    VoiceIndicatorView(
        state: .constant(ViewModelState.processingLLM), // Explicit type
        audioLevel: .constant(-50.0),
        ttsLevel: .constant(0.0)
    )
    .preferredColorScheme(.dark)
}

#Preview("Speaking Low") {
    VoiceIndicatorView(
        state: .constant(ViewModelState.speakingTTS), // Explicit type
        audioLevel: .constant(-50.0),
        ttsLevel: .constant(0.1)
    )
    .preferredColorScheme(.dark)
}

#Preview("Speaking High") {
    VoiceIndicatorView(
        state: .constant(ViewModelState.speakingTTS), // Explicit type
        audioLevel: .constant(-50.0),
        ttsLevel: .constant(0.9)
    )
    .preferredColorScheme(.dark)
}
