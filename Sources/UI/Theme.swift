import SwiftUI

/// The classic iPod look: near-white LCD with fine scanlines, brushed-silver
/// title bar, blue gradient selection, dark dimmed wheel on a black body.
enum Theme {
    // MARK: Screen

    /// LCD background (very light, slight vertical gradient).
    static let paper = Color(red: 0.945, green: 0.945, blue: 0.945)
    /// Top (brighter) stop of the LCD paper gradient.
    static let paperTop = Color(red: 0.973, green: 0.973, blue: 0.973)
    /// Bottom (darker) stop of the LCD paper gradient.
    static let paperBottom = Color(red: 0.912, green: 0.912, blue: 0.912)

    // Title bar brushed metal
    /// Highlight stop at the top of the brushed-metal bar.
    static let barTop = Color(red: 0.878, green: 0.878, blue: 0.878)
    /// Mid stop of the brushed-metal gradient.
    static let barMid = Color(red: 0.808, green: 0.812, blue: 0.820)
    /// Shadow stop at the bottom of the brushed-metal bar.
    static let barBottom = Color(red: 0.686, green: 0.690, blue: 0.700)
    /// Hairline separating the title bar from the screen content below.
    static let barBorder = Color(red: 0.42, green: 0.42, blue: 0.44)

    // Selection gradient
    /// Bright top stop of the blue selection gradient.
    static let selTop = Color(red: 0.475, green: 0.655, blue: 0.898)
    /// Mid stop of the blue selection gradient.
    static let selMid = Color(red: 0.263, green: 0.467, blue: 0.812)
    /// Deep bottom stop of the blue selection gradient.
    static let selBottom = Color(red: 0.204, green: 0.400, blue: 0.784)
    /// Stroke drawn around the selected row.
    static let selEdge = Color(red: 0.365, green: 0.537, blue: 0.847)

    // Text
    /// Primary text color on the light LCD.
    static let ink = Color.black
    /// Secondary text: hints, subtitles, unselected glyphs.
    static let inkDim = Color(red: 0.42, green: 0.42, blue: 0.44)

    // MARK: Device body / wheel

    /// Classic black device body.
    static let bodyColor = Color.black
    /// Wheel face — deliberately dim so it reads as hardware, not UI.
    static let wheelFace = Color(red: 0.125, green: 0.125, blue: 0.130)
    /// Darker shade of the wheel's recessed center button.
    static let wheelCenter = Color(red: 0.07, green: 0.07, blue: 0.074)
    /// Lighter shade at the wheel's outer edge.
    static let wheelEdge = Color(red: 0.175, green: 0.175, blue: 0.180)
    /// Glyph labels (MENU, ⏯, ⏮, ⏭) printed on the wheel face.
    static let wheelLabel = Color(red: 0.560, green: 0.560, blue: 0.575)

    // MARK: Device themes (0 = classic black, 1 = silver)

    /// User-facing device theme names, indexed by theme id (0-based).
    static let themeNames = ["Black", "Silver"]

    /// Device body color for a theme.
    ///
    /// - Parameter theme: 0 = classic black, 1 = silver.
    /// - Returns: That theme's body color.
    static func body(_ theme: Int) -> Color {
        theme == 1 ? Color(red: 0.82, green: 0.82, blue: 0.83) : bodyColor
    }
    /// Wheel-face color for a theme.
    ///
    /// - Parameter theme: 0 = classic black, 1 = silver.
    /// - Returns: That theme's wheel-face color.
    static func wheelFace(_ theme: Int) -> Color {
        theme == 1 ? Color(white: 0.88) : wheelFace
    }
    /// Wheel center-button color for a theme.
    ///
    /// - Parameter theme: 0 = classic black, 1 = silver.
    /// - Returns: That theme's center-button color.
    static func wheelCenter(_ theme: Int) -> Color {
        theme == 1 ? Color(white: 0.80) : wheelCenter
    }
    /// Wheel outer-edge color for a theme.
    ///
    /// - Parameter theme: 0 = classic black, 1 = silver.
    /// - Returns: That theme's wheel-edge color.
    static func wheelEdge(_ theme: Int) -> Color {
        theme == 1 ? Color(white: 0.66) : wheelEdge
    }
    /// Wheel label-glyph color for a theme.
    ///
    /// - Parameter theme: 0 = classic black, 1 = silver.
    /// - Returns: That theme's label color.
    static func wheelLabel(_ theme: Int) -> Color {
        theme == 1 ? Color(white: 0.22) : wheelLabel
    }

    // MARK: Fonts

    /// Settings-scaled font for feature screens, so the Font Size setting
    /// applies consistently everywhere.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, settings: AppSettings = .shared) -> Font {
        .system(size: (size * settings.fontMultiplier).rounded(), weight: weight)
    }

    /// Semibold row-title font for menu rows. Unlike `font(_:_)` this does
    /// NOT apply the Font Size setting — callers scale the size themselves
    /// when they want it.
    ///
    /// - Parameter size: Base point size.
    /// - Returns: The row font.
    static func row(_ size: CGFloat = 18.5) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    /// Bold title-bar font for screen titles.
    ///
    /// - Parameter size: Base point size (unscaled).
    /// - Returns: The bar-title font.
    static func barTitle(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }
    /// Medium-weight font for the title-bar clock.
    ///
    /// - Parameter size: Base point size (unscaled).
    /// - Returns: The clock font.
    static func barClock(_ size: CGFloat = 14.5) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
}

/// Selection blue gradient — usable both as a View and a ShapeStyle
/// (`AnyShapeStyle(SelectionGradient())`, `.fill(SelectionGradient())`).
struct SelectionGradient: View, ShapeStyle {
    /// The gradient definition, shared by both conformances.
    static let gradient = LinearGradient(
        stops: [
            .init(color: Theme.selTop, location: 0),
            .init(color: Theme.selMid, location: 0.45),
            .init(color: Theme.selBottom, location: 1),
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// Draws the gradient (the `View` conformance).
    var body: some View {
        Self.gradient
    }

    /// ShapeStyle conformance: resolves to the same fixed gradient so the
    /// type can back `fill`/`stroke` too, not just view drawing.
    ///
    /// - Parameter environment: The current environment (unused — the
    ///   gradient is theme-fixed, not adaptive).
    /// - Returns: The selection gradient.
    func resolve(in environment: EnvironmentValues) -> LinearGradient {
        Self.gradient
    }
}

/// Brushed-metal strip behind the title bar.
struct BrushedMetal: View {
    /// Renders the vertical metal gradient overlaid with fine horizontal
    /// pinstripes. The stripes are drawn once in a `Canvas` (immediate-mode
    /// drawing) instead of hundreds of stripe views.
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
    /// Renders the LCD's light vertical paper gradient.
    var body: some View {
        LinearGradient(
            colors: [Theme.paperTop, Theme.paper, Theme.paperBottom],
            startPoint: .top, endPoint: .bottom
        )
    }
}
