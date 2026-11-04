import SwiftUI

/// The classic iPod look: near-white LCD with fine scanlines, brushed-silver
/// title bar, blue gradient selection, dark dimmed wheel on a black body.
enum Theme {
    // MARK: Screen

    /// LCD background (very light, slight vertical gradient).
    static let paper = Color(red: 0.945, green: 0.945, blue: 0.945)
    static let paperTop = Color(red: 0.973, green: 0.973, blue: 0.973)
    static let paperBottom = Color(red: 0.912, green: 0.912, blue: 0.912)

    // Title bar brushed metal
    static let barTop = Color(red: 0.878, green: 0.878, blue: 0.878)
    static let barMid = Color(red: 0.808, green: 0.812, blue: 0.820)
    static let barBottom = Color(red: 0.686, green: 0.690, blue: 0.700)
    static let barBorder = Color(red: 0.42, green: 0.42, blue: 0.44)

    // Selection gradient
    static let selTop = Color(red: 0.475, green: 0.655, blue: 0.898)
    static let selMid = Color(red: 0.263, green: 0.467, blue: 0.812)
    static let selBottom = Color(red: 0.204, green: 0.400, blue: 0.784)
    static let selEdge = Color(red: 0.365, green: 0.537, blue: 0.847)

    // Text
    static let ink = Color.black
    static let inkDim = Color(red: 0.42, green: 0.42, blue: 0.44)

    // MARK: Device body / wheel

    static let bodyColor = Color.black
    /// Wheel face — deliberately dim so it reads as hardware, not UI.
    static let wheelFace = Color(red: 0.125, green: 0.125, blue: 0.130)
    static let wheelCenter = Color(red: 0.07, green: 0.07, blue: 0.074)
    static let wheelEdge = Color(red: 0.175, green: 0.175, blue: 0.180)
    static let wheelLabel = Color(red: 0.560, green: 0.560, blue: 0.575)
    static let wheelLabelLit = Color(red: 0.92, green: 0.92, blue: 0.93)

    // MARK: Fonts

    static func row(_ size: CGFloat = 18.5) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    static func barTitle(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }
    static func barClock(_ size: CGFloat = 14.5) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
}

/// Selection blue gradient — usable both as a View and a ShapeStyle
/// (`AnyShapeStyle(SelectionGradient())`, `.fill(SelectionGradient())`).
struct SelectionGradient: View, ShapeStyle {
    static let gradient = LinearGradient(
        stops: [
            .init(color: Theme.selTop, location: 0),
            .init(color: Theme.selMid, location: 0.45),
            .init(color: Theme.selBottom, location: 1),
        ],
        startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        Self.gradient
    }

    func resolve(in environment: EnvironmentValues) -> LinearGradient {
        Self.gradient
    }
}

/// Brushed-metal strip behind the title bar.
struct BrushedMetal: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Theme.barTop, location: 0),
                .init(color: Theme.barMid, location: 0.42),
                .init(color: Theme.barBottom, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(
            Canvas { ctx, size in
                // fine horizontal pinstripes
                var y: CGFloat = 0
                while y < size.height {
                    let r = CGRect(x: 0, y: y, width: size.width, height: 0.5)
                    ctx.fill(Path(r), with: .color(.black.opacity(0.05)))
                    y += 2
                }
            }
            .allowsHitTesting(false)
        )
    }
}

/// LCD paper: light vertical gradient like the classic's screen.
struct PaperBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Theme.paperTop, Theme.paper, Theme.paperBottom],
            startPoint: .top, endPoint: .bottom
        )
    }
}
