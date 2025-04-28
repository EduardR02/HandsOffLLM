import SwiftUI

// A Shape that draws a circle whose radius is modulated by two sine-waves.
// phase and amplitude animate over time to create a fluid, wavy border.
struct WaveCircle: Shape {
  var phase: Double
  var amplitude: Double
  var segments: Int
  var noiseOffset: Double

  // Make phase & amplitude animatable
  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(phase, amplitude) }
    set { phase = newValue.first; amplitude = newValue.second }
  }

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let baseR = min(rect.width, rect.height) / 2
    var path = Path()

    for i in 0...segments {
      let pct = Double(i) / Double(segments)
      let θ   = pct * 2 * .pi
      // two combined waves for a richer profile
      let w1  = sin(4 * θ + phase + noiseOffset)
      let w2  = 0.5 * sin(7 * θ - phase * 0.7 + noiseOffset)
      let wave = w1 + w2

      let r = baseR + CGFloat(wave) * CGFloat(amplitude) * baseR * 0.2
      let x = center.x + r * cos(CGFloat(θ))
      let y = center.y + r * sin(CGFloat(θ))
      let pt = CGPoint(x: x, y: y)

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

  var body: some View {
    Group {
      if isVisible {
        // TimelineView drives smooth animation at ~60fps
        TimelineView(.animation) { context in
          let t     = context.date.timeIntervalSinceReferenceDate
          let phase = t * 2.0
          let lvl   = audioService.rawAudioLevel
          let norm  = max(0, min(1, (lvl + 50) / 50))
          var amp   = Double(norm)

          // drive amplitude & palette by state + levels
          let (mainColors, strokeColors): ([Color], [Color]) = {
            switch state {
            case .listening:
              let colors = [Color.blue, Color.purple, Color.cyan, Color.blue]
              return (colors, [Color.cyan, Color.purple, Color.blue, Color.cyan])

            case .speakingTTS:
              let colors = [Color.pink, Color.purple, Color.pink]
              return (colors, [Color.purple, Color.pink, Color.purple])
            case .processingLLM, .fetchingTTS:
              amp = 0.5 // hard coded loading amp
              let colors = [Color.orange, Color.red, Color.yellow, Color.orange]
              return (colors, [Color.yellow, Color.red, Color.orange, Color.yellow])
            default:
              amp = 0.05  // hard coded idle amp
              let gray = [Color.gray.opacity(0.4), Color.gray.opacity(0.6), Color.gray.opacity(0.4)]
              return (gray, [Color.gray.opacity(0.6), Color.gray.opacity(0.4), Color.gray.opacity(0.6)])
            }
          }()

          ZStack {
            // 2) Main wavy fill
            WaveCircle(
              phase: -phase * 1.2,
              amplitude: amp,
              segments: 100,
              noiseOffset: 1
            )
            .fill(
              AngularGradient(
                gradient: Gradient(colors: mainColors),
                center: .center
              )
            )
            .padding(size * 0.08)

            // 3) Wavy outline stroke
            WaveCircle(
              phase: phase,
              amplitude: amp * 0.8,
              segments: 100,
              noiseOffset: 2
            )
            .stroke(
              AngularGradient(
                gradient: Gradient(colors: strokeColors),
                center: .center
              ),
              lineWidth: size * 0.04
            )
            .padding(size * 0.08)
          }
          .drawingGroup()
          .animation(.easeInOut(duration: 0.3), value: state)
        }
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .onAppear { isVisible = true }
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
