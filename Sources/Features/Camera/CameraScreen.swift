import SwiftUI
import AVFoundation
import UIKit

/// Camera: live preview inside the screen, wheel zoom, prev/next cycles the
/// aspect ratio, hold flips the lens, center captures, MENU opens options.
struct CameraScreen: View {
    /// App-wide model from the environment: navigation, wheel input, and
    /// the `camera` + `photos` services.
    @Environment(AppModel.self) private var model
    /// Persisted camera preferences (flash, aspect ratio, lens) and tick
    /// behavior for the options list.
    @EnvironmentObject private var settings: AppSettings

    /// Whether the Camera Options modal is showing (MENU toggles it).
    @State private var optionsOpen = false
    /// Highlighted row in the options panel; wheel ticks move it.
    @State private var optionsSelection = 0
    /// Drives the brief white full-screen flash on capture.
    @State private var flashOverlay = false
    /// Shows the "Saved…" toast; auto-hides after ~1.2–1.4 s.
    @State private var savedOverlay = false
    /// Timestamp of the last MENU press; a second press within 0.65 s
    /// exits the camera instead of toggling options.
    @State private var lastMenuTap = Date.distantPast
    /// Toast text ("Saved to Photos", "Video saved", …); empty falls back
    /// to the default "Saved to Photos" label.
    @State private var recordToast = ""
    /// Last lens flip. `.prevHold`/`.nextHold` REPEAT every ~0.18s while
    /// held (the track-scrub repeat) — flipping on each repeat toggles the
    /// lens back and forth, so only one flip lands per hold.
    @State private var lastFlipAt = Date.distantPast

    /// The active aspect ratio (display label + width/height) resolved
    /// from the persisted index, clamped so a stale stored index can't
    /// fall outside the list.
    private var aspect: (label: String, value: CGFloat) {
        AppSettings.aspectRatios[min(settings.cameraAspectIndex, AppSettings.aspectRatios.count - 1)]
    }

    /// The aspect-cropped, effect-tinted live preview (or the no-camera
    /// prompt) with the status/hint overlay and flash, toast, and options
    /// layers on top; claims the camera on appear and releases it on exit.
    var body: some View {
        ZStack {
            if model.camera.deviceAvailable {
                // Aspect-cropped live preview: resizing with the ratio so
                // changing 1:1/4:3/16:9 visibly reframes the view. The chosen
                // effect tints the preview (and is baked into photos).
                CameraSessionPreview(session: model.camera.session)
                    .aspectRatio(aspect.value, contentMode: .fit)
                    .saturation(model.camera.effect.saturation)
                    .hueRotation(.degrees(model.camera.effect.hueRotation))
                    .overlay {
                        if let tint = model.camera.effect.overlayColor {
                            tint
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipped()
                    .animation(.easeInOut(duration: 0.2), value: aspect.value)
                statusOverlay
            } else {
                PaperBackground()
                PromptPane(symbol: "camera.fill", text: "Camera is unavailable in the Simulator. Run on a device.")
            }

            if flashOverlay {
                Color.white.ignoresSafeArea().transition(.opacity)
            }

            if optionsOpen {
                ModalHost { optionsPanel }
                    .zIndex(2)
            }

            if savedOverlay {
                VStack {
                    Spacer()
                    Text(recordToast.isEmpty ? "Saved to Photos" : recordToast)
                        .font(Theme.font(12, .bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(.bottom, 34)
                }
                .transition(.opacity)
            }
        }
        .onWheel { handle($0) }
        .onAppear {
            model.transportClaimedByScreen = true
            model.camera.configureIfNeeded()
            model.camera.start()
        }
        .onDisappear {
            model.transportClaimedByScreen = false
            if model.camera.isRecording { model.camera.stopRecording() }
            model.camera.stop()
        }
    }

    // MARK: Overlays

    /// REC indicator (video mode) over the aspect badge.
    private var statusOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if model.camera.videoMode {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(model.camera.isRecording ? Color.red : Color.red.opacity(0.35))
                            .frame(width: 7, height: 7)
                        Text(model.camera.isRecording ? TimeFormat.mss(Double(model.camera.recordingSeconds)) : "READY")
                            .font(Theme.font(10, .bold).monospacedDigit())
                            .foregroundStyle(Color.white)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                    .padding(.trailing, 8)
                    .padding(.top, 4)
                } else {
                    Text(aspect.label)
                        .font(Theme.font(11, .bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                        .padding(.trailing, 8)
                        .padding(.top, 4)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                hint("Center", model.camera.videoMode ? (model.camera.isRecording ? "Stop" : "Record") : "Capture")
                hint("◀ ▶", "Ratio")
                hint("Hold ◀ ▶", "Flip")
                hint("MENU", "Options")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.45))
        }
        .allowsHitTesting(false)
    }

    /// One "key · action" hint pair in the bottom control bar.
    /// - Parameters:
    ///   - key: The button label (e.g. "MENU").
    ///   - action: What it does (e.g. "Options").
    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(Theme.font(9.5, .bold))
            Text(action)
                .font(Theme.font(9.5, .medium))
        }
        .foregroundStyle(Color.white.opacity(0.92))
    }

    /// Flash choices in cycling order: display label paired with the
    /// matching AVCaptureDevice.FlashMode.
    private var flashModes: [(String, AVCaptureDevice.FlashMode)] {
        [("Off", .off), ("On", .on), ("Auto", .auto)]
    }

    /// The options-panel rows; details and ✓ marks re-derive from live
    /// settings/model state on every render, so cycling a value in
    /// `activateOption` updates the panel with no manual bookkeeping.
    private var optionsItems: [MenuItem] {
        [
            MenuItem(id: "flash", title: "Flash", detail: flashModes[min(settings.cameraFlash, 2)].0, showsChevron: false),
            MenuItem(id: "mode", title: "Mode", detail: model.camera.videoMode ? "Video" : "Photo", showsChevron: false),
            MenuItem(id: "effect", title: "Photo Effect", detail: model.camera.effect.rawValue, showsChevron: false),
            MenuItem(id: "back", title: "Back Camera", detail: settings.cameraFront ? nil : "✓", showsChevron: false),
            MenuItem(id: "front", title: "Selfie Camera", detail: settings.cameraFront ? "✓" : nil, showsChevron: false),
            MenuItem(id: "ratio", title: "Aspect Ratio", detail: aspect.label, showsChevron: false),
        ]
    }

    /// The modal options list over the preview, navigated with the wheel.
    private var optionsPanel: some View {
        ModalPanel(title: "Camera Options", onClose: { optionsOpen = false }) {
            VStack(spacing: 0) {
                ForEach(Array(optionsItems.enumerated()), id: \.element.id) { i, item in
                    MenuRow(item: item, selected: optionsSelection == i)
                        .frame(height: 30.5)
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Input

    /// Routes every wheel/button event for the camera screen.
    ///
    /// While the options panel is open, ticks and center drive the panel
    /// instead of zoom/capture. Single MENU toggles options; a second MENU
    /// within 0.65 s exits; MENU-hold goes home. prev/next cycle the
    /// aspect ratio. prevHold/nextHold flip the lens, RATE-LIMITED to one
    /// flip per hold: hold events repeat every ~0.18 s while the button
    /// stays down, and an unthrottled handler toggled the lens back and
    /// forth within a single hold. This screen also claims the transport
    /// buttons via `model.transportClaimedByScreen` on appear, so
    /// prev/next/play/pause arrive here instead of controlling music.
    /// - Parameter event: The control event delivered by the click wheel.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if optionsOpen {
                moveListSelection(&optionsSelection, count: optionsItems.count, delta: d, settings: settings)
            } else {
                model.camera.bumpZoom(d)
            }
        case .select:
            if optionsOpen {
                activateOption()
            } else if model.camera.videoMode {
                toggleRecording()
            } else {
                capturePhoto()
            }
        case .menu:
            // Double-tap MENU (within 0.65 s) exits the camera; a single tap
            // toggles the options panel.
            if Date().timeIntervalSince(lastMenuTap) < 0.65 {
                lastMenuTap = .distantPast
                withAnimation(.easeOut(duration: 0.18)) { optionsOpen = false }
                model.pop()
            } else {
                lastMenuTap = Date()
                withAnimation(.easeOut(duration: 0.18)) {
                    optionsOpen.toggle()
                }
                optionsSelection = 0
            }
        case .prev:
            if !optionsOpen {
                settings.cameraAspectIndex = (settings.cameraAspectIndex + AppSettings.aspectRatios.count - 1) % AppSettings.aspectRatios.count
            }
        case .next:
            if !optionsOpen {
                settings.cameraAspectIndex = (settings.cameraAspectIndex + 1) % AppSettings.aspectRatios.count
            }
        case .prevHold, .nextHold:
            // First fire flips; the ~0.18s repeats (which arrive for as
            // long as the button is held) are swallowed — one flip per hold.
            if !optionsOpen, Date().timeIntervalSince(lastFlipAt) > 0.6 {
                lastFlipAt = Date()
                model.camera.setFront(!model.camera.isFront)
                settings.cameraFront = !settings.cameraFront
            }
        case .holdEnded:
            break
        case .menuHold:
            model.popToRoot()
        default:
            break
        }
    }

    /// Applies the highlighted options row: Flash and Photo Effect cycle
    /// through their values, Mode toggles photo/video, the lens rows
    /// switch cameras (✓ marks the active one), Aspect Ratio cycles.
    private func activateOption() {
        let id = optionsItems[min(optionsSelection, optionsItems.count - 1)].id
        switch id {
        case "flash":
            settings.cameraFlash = (settings.cameraFlash + 1) % 3
        case "mode":
            model.camera.setVideoMode(!model.camera.videoMode)
        case "effect":
            let all = CameraEffect.allCases
            let idx = all.firstIndex(of: model.camera.effect) ?? 0
            model.camera.effect = all[(idx + 1) % all.count]
        case "back":
            if settings.cameraFront { model.camera.setFront(false); settings.cameraFront = false }
        case "front":
            if !settings.cameraFront { model.camera.setFront(true); settings.cameraFront = true }
        case "ratio":
            settings.cameraAspectIndex = (settings.cameraAspectIndex + 1) % AppSettings.aspectRatios.count
        default:
            break
        }
    }

    /// Center press in video mode: stops an in-flight recording, or starts
    /// one — the completion callback reports "Video saved" or "Recording
    /// Failed" as a toast and auto-hides it.
    private func toggleRecording() {
        if model.camera.isRecording {
            model.camera.stopRecording()
        } else {
            model.camera.startRecording { ok in
                recordToast = ok ? "Video saved" : "Recording Failed"
                withAnimation(.easeOut(duration: 0.2)) { savedOverlay = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation(.easeIn(duration: 0.3)) { savedOverlay = false; recordToast = "" }
                }
            }
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 1.0)
        }
    }

    /// Center press in photo mode: the full capture pipeline.
    ///
    /// Plays the flash blink, captures, center-crops to the active aspect
    /// ratio, bakes in the selected photo effect, saves to the library,
    /// and toasts the result. A failed save (typically a missing
    /// photo-add permission) is silent — the shot isn't kept anywhere
    /// else, so it is lost.
    private func capturePhoto() {
        let flash = flashModes[min(settings.cameraFlash, 2)].1
        withAnimation(.easeOut(duration: 0.06)) { flashOverlay = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeIn(duration: 0.18)) { flashOverlay = false }
        }

        Task {
            guard let raw = await model.camera.capture(flashMode: flash) else { return }
            let cropped = CameraCapture.crop(raw, toRatio: aspect.value)
            let processed = model.camera.effect.apply(to: cropped)
            do {
                try await model.photos.saveToLibrary(processed)
                recordToast = model.camera.effect == .none ? "Saved to Photos" : "Saved · \(model.camera.effect.rawValue)"
                withAnimation(.easeOut(duration: 0.2)) { savedOverlay = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeIn(duration: 0.3)) { savedOverlay = false; recordToast = "" }
                }
            } catch {
                // Saving failed (likely missing photo permission); photo lost silently.
            }
        }
    }
}

/// AVCaptureVideoPreviewLayer host; sized by the parent to the aspect ratio.
private struct CameraSessionPreview: UIViewRepresentable {
    /// The capture session to render — the app's single camera session.
    let session: AVCaptureSession

    /// UIKit view whose backing layer IS the video preview layer.
    /// Overriding `layerClass` (rather than adding the preview layer as a
    /// sublayer) lets the video resize automatically with the view and
    /// skips a layer of compositing — the standard UIKit pattern for
    /// layer-backed views.
    /// Concept: AVCaptureVideoPreviewLayer → docs/concepts/avfoundation-camera.md
    final class PreviewView: UIView {
        /// Makes UIKit back every PreviewView with a video preview layer
        /// instead of the default plain CALayer.
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        /// The backing layer cast back to its concrete type for session
        /// and video-gravity access.
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    /// Creates the preview view once: attaches the session and fills the
    /// bounds with video (cropping overflow rather than letterboxing).
    /// - Parameter context: SwiftUI context (unused).
    /// - Returns: The configured preview view.
    /// Concept: UIViewRepresentable → docs/concepts/uiviewrepresentable.md
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    /// No-op: the session is attached once at creation and never changes.
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
