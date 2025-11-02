import SwiftUI
import simd

// A Shape that draws a circle whose radius is modulated by two sine-waves.
// phase and amplitude animate over time to create a fluid, wavy border.
struct WaveCircle: Shape {
    var phase: Double
    var amplitude: Double
    var noiseOffset: Double
    
    // Precomputed angle steps
    static let segmentCount = 100
    static let theta: [Double]      = (0...segmentCount).map { Double($0)/Double(segmentCount) * 2 * .pi }
    // Precomputed sin/cos as CGFloat to avoid per-frame casts
    static let sin4theta: [CGFloat] = theta.map { CGFloat(sin(4 * $0)) }
    static let cos4theta: [CGFloat] = theta.map { CGFloat(cos(4 * $0)) }
    static let sin7theta: [CGFloat] = theta.map { CGFloat(sin(7 * $0)) }
    static let cos7theta: [CGFloat] = theta.map { CGFloat(cos(7 * $0)) }
    static let cosTheta: [CGFloat]  = theta.map { CGFloat(cos($0)) }
    static let sinTheta: [CGFloat]  = theta.map { CGFloat(sin($0)) }
    
    // Make phase & amplitude animatable
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, amplitude) }
        set { phase = newValue.first; amplitude = newValue.second }
    }
    
    func path(in rect: CGRect) -> Path {
        // Precompute constants
        let centerX = rect.midX, centerY = rect.midY
        let baseR = min(rect.width, rect.height) / 2
        let p1 = phase + noiseOffset, p2 = -phase * 0.7 + noiseOffset
        let c1f = CGFloat(cos(p1)), s1f = CGFloat(sin(p1))
        let c2f = CGFloat(cos(p2)), s2f = CGFloat(sin(p2))
        let scale = CGFloat(amplitude) * baseR * 0.2
        var path = Path()
        
        for i in 0...WaveCircle.segmentCount {
            // combine waves and compute radius
            let waveVal = WaveCircle.sin4theta[i]*c1f + WaveCircle.cos4theta[i]*s1f
            + 0.5*(WaveCircle.sin7theta[i]*c2f + WaveCircle.cos7theta[i]*s2f)
            let r = baseR + waveVal * scale
            let pt = CGPoint(x: centerX + r * WaveCircle.cosTheta[i], y: centerY + r * WaveCircle.sinTheta[i])
            
            if i == 0 { path.move(to: pt) }
            else     { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

// File-level constants for smoothing
fileprivate let defaultMinAmplitude: Double = 0.15

// File-level amp holder for smoothing state between frames
@MainActor
fileprivate struct AmpHolder {
    static var displayedAmp: Double = defaultMinAmplitude
}

private extension Color {
    func simdRGBA() -> SIMD4<Float> {
        #if canImport(UIKit)
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return SIMD4(Float(r), Float(g), Float(b), Float(a))
        }
        
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = uiColor.cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
           let components = converted.components {
            let red = components.count > 0 ? components[0] : 1
            let green = components.count > 1 ? components[1] : red
            let blue = components.count > 2 ? components[2] : green
            let alpha = components.count > 3 ? components[3] : 1
            return SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
        }
        #elseif canImport(AppKit)
        let nsColor = NSColor(self)
        guard let color = nsColor.usingColorSpace(.genericRGB) else {
            return SIMD4(1, 1, 1, 1)
        }
        return SIMD4(Float(color.redComponent),
                     Float(color.greenComponent),
                     Float(color.blueComponent),
                     Float(color.alphaComponent))
        #endif
        return SIMD4(1, 1, 1, 1)
    }
    
    func blended(with other: Color, amount: Double) -> Color {
        let primary = simdRGBA()
        let secondary = other.simdRGBA()
        let t = Float(max(0.0, min(1.0, amount)))
        let blend = primary * (1 - t) + secondary * t
        return Color(.sRGB,
                     red: Double(blend.x),
                     green: Double(blend.y),
                     blue: Double(blend.z),
                     opacity: Double(blend.w))
    }
}

private func normalizedPalette(_ colors: [Color]) -> [Color] {
    guard !colors.isEmpty else {
        return [Color.white, Color.white]
    }
    if colors.count == 1, let first = colors.first {
        return [first, first]
    }
    return colors
}

private func blendedStrokePalette(fill: [Color], stroke: [Color]) -> [Color] {
    let baseFill = normalizedPalette(fill)
    let baseStroke = normalizedPalette(stroke)
    let maxCount = max(baseFill.count, baseStroke.count)
    return (0..<maxCount).map { index in
        let strokeColor = baseStroke[index % baseStroke.count]
        let fillColor = baseFill[index % baseFill.count]
        return strokeColor.blended(with: fillColor, amount: 0.35)
    }
}

struct VoiceIndicatorView: View {
    @Binding var state: ViewModelState
    @EnvironmentObject var audioService: AudioService
    @EnvironmentObject var settingsService: SettingsService
    @State private var isVisible: Bool = false
    
    // Circle size
    private let size: CGFloat = 320
    
    // Cached color palettes (updated on state change)
    @State private var mainColors: [Color]   = []
    @State private var strokeColors: [Color] = []
    
    private func updateColors(for state: ViewModelState) {
        let fillPalette: [Color]
        let strokePalette: [Color]
        
        switch state {
        case .listening:
            fillPalette   = [Color.blue,
                             Color(red: 11/255, green: 219/255, blue: 182/255),
                             Color.cyan,
                             Color.blue]
            strokePalette = [Color.cyan,
                             Color(red: 8/255, green: 164/255, blue: 167/255),
                             Color.blue,
                             Color.cyan]
        case .speakingTTS:
            fillPalette   = [Color.pink, Color.purple, Color.pink]
            strokePalette = [Color.purple, Color.pink, Color.purple]
        case .processingLLM, .fetchingTTS:
            fillPalette   = [Color.orange, Color.red, Color.yellow, Color.orange]
            strokePalette = [Color.yellow, Color.red, Color.orange, Color.yellow]
        default:
            fillPalette   = [Color.gray.opacity(0.4),
                             Color.gray.opacity(0.6),
                             Color.gray.opacity(0.4)]
            strokePalette = [Color.gray.opacity(0.6),
                             Color.gray.opacity(0.4),
                             Color.gray.opacity(0.6)]
        }
        
        mainColors = normalizedPalette(fillPalette)
        strokeColors = blendedStrokePalette(fill: mainColors, stroke: strokePalette)
    }
    
    // Extract common timeline rendering logic
    @ViewBuilder
    private func indicatorTimeline<Schedule: TimelineSchedule>(_ schedule: Schedule) -> some View {
        TimelineView(schedule) { context in
            let t     = context.date.timeIntervalSinceReferenceDate
            let phase = t * 2.0
            let lvl   = Double(audioService.rawAudioLevel)
            let norm  = max(0.0, min(1.0, (lvl + 50.0) / 50.0))

            let smoothingFactor = 0.2
            let minAmplitude    = defaultMinAmplitude
            var targetAmp       = max(norm, minAmplitude)
            switch state {
                case .processingLLM, .fetchingTTS: targetAmp = 0.4
                case .idle, .error:                 targetAmp = minAmplitude
                default:                           targetAmp = minAmplitude + (1 - minAmplitude) * norm
            }
            // Update and use global amp holder
            AmpHolder.displayedAmp += (targetAmp - AmpHolder.displayedAmp) * smoothingFactor
            let ampToUse = AmpHolder.displayedAmp

            return ZStack {
                WaveCircle(phase: -phase * 1.2, amplitude: ampToUse, noiseOffset: 1)
                    .fill(AngularGradient(gradient: Gradient(colors: mainColors), center: .center))
                    .animation(.easeInOut(duration: 0.15), value: mainColors)

                WaveCircle(phase: phase, amplitude: ampToUse * 0.8, noiseOffset: 2)
                    .stroke(AngularGradient(gradient: Gradient(colors: strokeColors), center: .center), lineWidth: size * 0.035)
                    .blendMode(.plusLighter)
                    .animation(.easeInOut(duration: 0.15), value: strokeColors)
            }
            .padding(size * 0.1)
            .drawingGroup()
        }
    }

    var body: some View {
        Group {
            if isVisible {
                if settingsService.energySaverEnabled {
                    indicatorTimeline(.everyMinute)
                } else {
                    indicatorTimeline(.animation)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .background(Theme.background)
        .onAppear {
            isVisible = true
            updateColors(for: state)
        }
        .onChange(of: state) { old, new in
            updateColors(for: new)
        }
        .onDisappear { isVisible = false }
    }
}

struct VoiceIndicatorView_Previews: PreviewProvider {
    static var previews: some View {
        // Set up environment objects needed by the view
        let settings = SettingsService()
        let history  = HistoryService()
        let audio    = AudioService(settingsService: settings, historyService: history)

        return StatefulPreviewWrapper(ViewModelState.listening) { state in
            VoiceIndicatorView(state: state)
                .environmentObject(settings)
                .environmentObject(audio)
        }
    }
}

// A helper struct to wrap a View that uses @Binding for previews
struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private var content: (Binding<Value>) -> Content
    
    init(_ value: Value, content: @escaping (Binding<Value>) -> Content) {
        self._value = State(wrappedValue: value)
        self.content = content
    }
    
    var body: some View {
        content($value)
    }
}
