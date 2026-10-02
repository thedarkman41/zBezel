import SwiftUI

/// A test target that shows what each sharpness step does to an edge.
///
/// Monitor sharpness is edge enhancement, not detail: turned down it softens
/// transitions, turned up it adds overshoot — a bright fringe on the light side
/// of an edge and a dark one on the other. Line pairs and hard-cornered shapes
/// show both effects far more plainly than a photograph, which is why every
/// resolution chart ever printed looks like this.
///
/// It is a SIMULATION, drawn by the Mac. The panel's own scaler is what actually
/// changes, and nothing reports the shape of its filter, so this shows the
/// character of the setting rather than a prediction of the output. Labeled as
/// such, because a preview that quietly implies measurement would be worse than
/// no preview.
struct SharpnessPreview: View {
    /// 0 for the softest step, 1 for the sharpest.
    let level: Double

    private var softness: CGFloat { CGFloat(1 - level) * 1.5 }
    /// Overshoot only appears in the upper half of the range, as it does on a
    /// real panel — the lower steps soften rather than ring.
    private var overshoot: Double { max(0, (level - 0.45) / 0.55) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.08))
                target
                    .blur(radius: softness)
                if overshoot > 0 {
                    target
                        .offset(x: 0.8)
                        .blendMode(.plusLighter)
                        .opacity(overshoot * 0.55)
                    target
                        .offset(x: -0.8)
                        .blendMode(.multiply)
                        .opacity(overshoot * 0.45)
                }
            }
            .frame(height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            Text("Simulated — the character of each step, not the panel's output.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
        }
    }

    private var target: some View {
        Canvas { ctx, size in
            let h = size.height
            let inset: CGFloat = 5
            var x = inset

            // Line pairs at a shrinking pitch: the classic resolution wedge. The
            // finest pairs are the first to smear when the edge is softened.
            for pitch in stride(from: 7.0, through: 2.0, by: -1.0) {
                for _ in 0..<3 {
                    ctx.fill(Path(CGRect(x: x, y: inset,
                                         width: pitch / 2, height: h - inset * 2)),
                             with: .color(.white))
                    x += pitch
                }
                x += 3
            }

            x += 4
            // A hard step edge — where overshoot is most visible.
            ctx.fill(Path(CGRect(x: x, y: inset, width: 18, height: h - inset * 2)),
                     with: .color(.white))
            x += 26

            // Curves and diagonals, which ring differently from straight edges.
            var circle = Path()
            circle.addEllipse(in: CGRect(x: x, y: inset + 1,
                                         width: h - inset * 2 - 2, height: h - inset * 2 - 2))
            ctx.stroke(circle, with: .color(.white), lineWidth: 1.4)
            x += h - inset

            var diagonal = Path()
            diagonal.move(to: CGPoint(x: x + 4, y: h - inset))
            diagonal.addLine(to: CGPoint(x: x + 22, y: inset))
            diagonal.move(to: CGPoint(x: x + 12, y: h - inset))
            diagonal.addLine(to: CGPoint(x: x + 30, y: inset))
            ctx.stroke(diagonal, with: .color(.white), lineWidth: 1.4)
        }
    }
}
