import SwiftUI

// MARK: - SpeedGraph
// A tiny sparkline-style bandwidth graph for the upload center header.

struct SpeedGraph: View {
    var samples: [Double]  // BPS values, most recent last
    var color: Color = .accentColor
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let max = samples.max() ?? 1

            Path { path in
                guard samples.count > 1 else { return }
                let step = w / CGFloat(samples.count - 1)
                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) * step
                    let y = h - (CGFloat(sample / max) * h)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // Fill gradient under line
            Path { path in
                guard samples.count > 1 else { return }
                let step = w / CGFloat(samples.count - 1)
                path.move(to: CGPoint(x: 0, y: h))
                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) * step
                    let y = h - (CGFloat(sample / max) * h)
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.closeSubpath()
            }
            .fill(color.opacity(0.15))
        }
    }
}

// MARK: - BandwidthSlider

struct BandwidthSlider: View {
    @Binding var limitMBps: Double
    let range: ClosedRange<Double>
    var onCommit: ((Double) -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "speedometer")
                .foregroundColor(.textSecondary)
            Slider(value: $limitMBps, in: range, step: 1) { editing in
                if !editing { onCommit?(limitMBps) }
            }
            Text(limitMBps >= range.upperBound
                 ? "Unlimited"
                 : String(format: "%.0f MB/s", limitMBps))
                .font(.stratusMonospace)
                .frame(width: 80, alignment: .trailing)
        }
    }
}
