import SwiftUI

/// Il cuore dell'icona (stesse curve di tools/genera_icona.swift, normalizzate).
struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Spazio sorgente: x 172…852, y 190…880 nel quadrato 1024 dell'icona.
        let sx = rect.width / 680, sy = rect.height / 690
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 172) * sx, y: rect.minY + (y - 190) * sy)
        }
        var path = Path()
        path.move(to: p(512, 330))
        path.addCurve(to: p(196, 420), control1: p(452, 196), control2: p(224, 190))
        path.addCurve(to: p(512, 880), control1: p(172, 600), control2: p(392, 752))
        path.addCurve(to: p(828, 420), control1: p(632, 752), control2: p(852, 600))
        path.addCurve(to: p(512, 330), control1: p(800, 190), control2: p(572, 196))
        path.closeSubpath()
        return path
    }
}

/// La freccia scavata nel cuore.
struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 680, sy = rect.height / 690
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 172) * sx, y: rect.minY + (y - 190) * sy)
        }
        var path = Path()
        path.move(to: p(512, 664))
        path.addLine(to: p(512, 250))
        path.move(to: p(402, 380))
        path.addLine(to: p(512, 266))
        path.addLine(to: p(622, 380))
        return path
    }
}

/// Marchio animato: cuore pieno con freccia che "respira" verso l'alto.
struct BrandMark: View {
    var size: CGFloat = 120
    var fill: AnyShapeStyle = AnyShapeStyle(Color.white)
    var animated = true
    @State private var lift = false

    var body: some View {
        ZStack {
            HeartShape().fill(fill)
            ArrowShape()
                .stroke(style: StrokeStyle(lineWidth: size * 0.112, lineCap: .round, lineJoin: .round))
                .offset(y: lift ? -size * 0.035 : size * 0.01)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: size, height: size * 690 / 680)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { lift = true }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    BrandMark().padding().background(LinearGradient.diagonal(Palette.brand))
}
