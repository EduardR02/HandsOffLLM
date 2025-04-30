import SwiftUI

// A Shape that draws a circle whose radius is modulated by two sine-waves.
// phase and amplitude animate over time to create a fluid, wavy border.
struct WaveCircle: Shape {
    var phase: Double
    var amplitude: Double
    var noiseOffset: Double
    
    // Static trig lookup tables for 100 segments
    static let segmentCount = 100
    static let theta: [Double]      = (0...segmentCount).map { Double($0)/Double(segmentCount) * 2 * .pi }
    static let sin4theta: [Double]  = theta.map { sin(4 * $0) }
    static let cos4theta: [Double]  = theta.map { cos(4 * $0) }
    static let sin7theta: [Double]  = theta.map { sin(7 * $0) }
    static let cos7theta: [Double]  = theta.map { cos(7 * $0) }
    static let cosTheta: [CGFloat]  = theta.map { CGFloat(cos($0)) }
    static let sinTheta: [CGFloat]  = theta.map { CGFloat(sin($0)) }
    
    // Make phase & amplitude animatable
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, amplitude) }
        set { phase = newValue.first; amplitude = newValue.second }
    }
    
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseR  = min(rect.width, rect.height) / 2
        var path   = Path()
        
        // Precompute phase+offset trig
        let p1 = phase + noiseOffset, c1 = cos(p1), s1 = sin(p1)
        let p2 = -phase * 0.7 + noiseOffset, c2 = cos(p2), s2 = sin(p2)
        
        for i in 0...WaveCircle.segmentCount {
            // combine precomputed waves via angle-addition
            let waveVal = WaveCircle.sin4theta[i]*c1 + WaveCircle.cos4theta[i]*s1
            + 0.5*(WaveCircle.sin7theta[i]*c2 + WaveCircle.cos7theta[i]*s2)
            let r    = baseR + CGFloat(waveVal) * CGFloat(amplitude) * baseR * 0.2
            let pt   = CGPoint(x: center.x + r * WaveCircle.cosTheta[i], y: center.y + r * WaveCircle.sinTheta[i])
            
            if i == 0 { path.move(to: pt) }
            else     { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

struct VoiceIndicatorView: View {
    @Binding var state: ViewModelState
    @EnvironmentObject var audioService: AudioService
    @State private var isVisible: Bool = false
    
    // Circle size
    private let size: CGFloat = 240
    
    // Cached color palettes (updated on state change)
    @State private var mainColors: [Color]   = []
    @State private var strokeColors: [Color] = []
    
    private func updateColors(for state: ViewModelState) {
        switch state {
        case .listening:
            mainColors   = [Color.blue, Color.purple, Color.cyan, Color.blue]
            strokeColors = [Color.cyan, Color.purple, Color.blue, Color.cyan]
        case .speakingTTS:
            mainColors   = [Color.pink, Color.purple, Color.pink]
            strokeColors = [Color.purple, Color.pink, Color.purple]
        case .processingLLM, .fetchingTTS:
            mainColors   = [Color.orange, Color.red, Color.yellow, Color.orange]
            strokeColors = [Color.yellow, Color.red, Color.orange, Color.yellow]
        default:
            mainColors   = [Color.gray.opacity(0.4), Color.gray.opacity(0.6), Color.gray.opacity(0.4)]
            strokeColors = [Color.gray.opacity(0.6), Color.gray.opacity(0.4), Color.gray.opacity(0.6)]
        }
    }
    
    var body: some View {
        Group {
            if isVisible {
                // TimelineView drives smooth animation at ~60fps
                TimelineView(.animation) { context in
                    let t     = context.date.timeIntervalSinceReferenceDate
                    let phase = t * 2.0
                    let lvl = Double(audioService.rawAudioLevel)
                    let norm = max(0.0, min(1.0, (lvl + 50.0) / 50.0))

                    // Smoothing factor: closer to 1 = faster response, closer to 0 = slower/smoother
                    let smoothingFactor = 0.2
                    let minAmplitude = 0.15

                    // Determine target amplitude and enforce global minimum
                    var targetAmp = max(norm, minAmplitude)
                    switch state {
                    case .processingLLM, .fetchingTTS:
                        targetAmp = 0.5
                    case .idle, .error:
                        targetAmp = minAmplitude
                    default:
                        // Use minAmplitude as baseline, add dynamic part above it
                        targetAmp = minAmplitude + (1 - minAmplitude) * norm
                    }

                    // Use static to persist amplitude between frames
                    struct Holder { static var displayedAmp: Double = 0.15 }
                    Holder.displayedAmp += (targetAmp - Holder.displayedAmp) * smoothingFactor
                    let ampToUse = Holder.displayedAmp

                    return ZStack {
                        // 2) Main wavy fill
                        WaveCircle(
                            phase: -phase * 1.2,
                            amplitude: ampToUse,
                            noiseOffset: 1
                        )
                        .fill(
                            AngularGradient(
                                gradient: Gradient(colors: mainColors),
                                center: .center
                            )
                        )
                        .padding(size * 0.1)
                        .animation(.easeInOut(duration: 0.15), value: mainColors)

                        // 3) Wavy outline stroke
                        WaveCircle(
                            phase: phase,
                            amplitude: ampToUse * 0.8,
                            noiseOffset: 2
                        )
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: strokeColors),
                                center: .center
                            ),
                            lineWidth: size * 0.04
                        )
                        .padding(size * 0.1)
                        .animation(.easeInOut(duration: 0.15), value: strokeColors)
                    }
                    .drawingGroup()
                }
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
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
        StatefulPreviewWrapper(ViewModelState.listening) { state in
            VoiceIndicatorView(
                state: state
            )
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
