import SwiftUI

/// The subtle CRT look over the LCD: horizontal scanlines, faint vignette,
/// slight bloom. Intensity configurable; off when disabled in Display.
struct CRTOverlay: View {
    @EnvironmentObject private var settings: AppSettings

    /// Renders the effect stack — scanlines, vignette, faint bloom — only
    /// when the CRT setting is on; hit-testing is disabled so it never
    /// intercepts screen taps.
    var body: some View {
        if settings.crtEnabled {
            ZStack {
                Scanlines(opacity: levelOpacity)
                Vignette()
                Color.white.opacity(0.018)
            }
            .allowsHitTesting(false)
        }
    }

    /// Maps the Display setting's scanline-intensity level to the scanline
    /// opacity (0 = invisible).
    private var levelOpacity: Double {
        switch settings.scanlineIntensity {
        case 0: return 0
        case 2: return 0.085
        case 3: return 0.13
        default: return 0.05
        }
    }
}

/// The scanline layer: 1-pt dark lines every 3 pt, every third line at
/// full strength and the rest fainter, drawn in a Canvas so hundreds of
/// lines cost one draw pass instead of hundreds of views.
private struct Scanlines: View {
    /// Base darkness of each line.
    let opacity: Double

    /// Paints the repeating horizontal lines across the full size.
    var body: some View {
        Canvas { ctx, size in
            guard opacity > 0 else { return }
            var y: CGFloat = 1
            var i = 0
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                ctx.opacity = (i % 3 == 0) ? opacity : opacity * 0.55
                ctx.fill(Path(rect), with: .color(.black))
                y += 3
                i += 1
            }
        }
    }
}

/// The vignette layer: a radial gradient that darkens the LCD's corners
/// slightly, like a photographed tube.
private struct Vignette: View {
    /// Renders the radial corner darkening.
    var body: some View {
        RadialGradient(
            colors: [.black.opacity(0), .black.opacity(0), .black.opacity(0.075)],
            center: .center, startRadius: 60, endRadius: 260
        )
    }
}
