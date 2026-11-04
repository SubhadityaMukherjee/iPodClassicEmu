import SwiftUI

private struct AcceptsWheelInputKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

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

    let action: (ControlEvent) -> Void

    func body(content: Content) -> some View {
        content.onReceive(model.controlBus) { event in
            if accepts { action(event) }
        }
    }
}

extension View {
    /// Subscribe to click wheel events; active only when this screen is the
    /// top of the navigation stack.
    func onWheel(_ action: @escaping (ControlEvent) -> Void) -> some View {
        modifier(WheelSink(action: action))
    }
}
