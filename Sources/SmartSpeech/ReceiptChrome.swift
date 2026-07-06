import SwiftUI

/// Shared "receipt" chrome used by the Nerd Stats page and the per-book player panel: a torn-edge
/// outline and a dashed separator rule, so both surfaces read as the same paper receipt.

/// A horizontal dashed rule — the receipt separators.
struct DashedRule: View {
    var body: some View {
        DashLine()
            .stroke(Color(.systemGray3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
    }
    private struct DashLine: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

/// A receipt outline: flat sides with a torn (sawtooth) top and bottom edge.
struct ReceiptShape: Shape {
    var tooth: CGFloat = 9
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = tooth, h = tooth / 2
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + h))
        var x = rect.minX
        var up = true
        while x < rect.maxX {
            let nx = min(x + t, rect.maxX)
            p.addLine(to: CGPoint(x: nx, y: rect.minY + (up ? 0 : h)))
            up.toggle(); x = nx
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - h))
        x = rect.maxX; up = true
        while x > rect.minX {
            let nx = max(x - t, rect.minX)
            p.addLine(to: CGPoint(x: nx, y: rect.maxY - (up ? 0 : h)))
            up.toggle(); x = nx
        }
        p.closeSubpath()
        return p
    }
}
