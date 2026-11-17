import SwiftUI

/// Storage type for the `acceptsWheelInput` environment value. SwiftUI
/// environment values are addressed by key type; this key defaults to
/// `true` so views outside `ScreenRouter`'s stack (sheets, the device
/// shell) still receive wheel events without opting in.
///
/// Concept: SwiftUI views and state → docs/concepts/swiftui-views-and-state.md
private struct AcceptsWheelInputKey: EnvironmentKey {
    /// `true` unless a container (ScreenRouter) explicitly gates a layer.
    static let defaultValue: Bool = true
}

/// Exposes the wheel-input gate as a SwiftUI environment value.
extension EnvironmentValues {
    /// Only the top screen in the navigation stack should react to the wheel.
    /// ScreenRouter sets this per stacked layer; covered screens stay mounted
    /// (for state) but stop listening.
    var acceptsWheelInput: Bool {
        get { self[AcceptsWheelInputKey.self] }
        set { self[AcceptsWheelInputKey.self] = newValue }
    }
}

/// Replacement for `.onReceive(model.controlBus)` on screens inside the nav
/// stack: the handler only fires while the screen is on top.
struct WheelSink: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.acceptsWheelInput) private var accepts

    /// Invoked for each wheel event while this screen is on top.
    ///
    /// Concept: Swift closures → docs/concepts/swift-closures.md
    let action: (ControlEvent) -> Void

    /// Subscribes to the app-wide control bus, forwarding events to
    /// `action` only while the environment marks this layer as accepting
    /// input (top of the nav stack).
    ///
    /// Concept: Combine → docs/concepts/combine.md
    func body(content: Content) -> some View {
        content.onReceive(model.controlBus) { event in
            if accepts { action(event) }
        }
    }
}

/// Adds `onWheel(_:)` to every view.
extension View {
    /// Subscribe to click wheel events; active only when this screen is the
    /// top of the navigation stack.
    func onWheel(_ action: @escaping (ControlEvent) -> Void) -> some View {
        modifier(WheelSink(action: action))
    }
}
