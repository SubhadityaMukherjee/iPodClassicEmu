import SwiftUI
import AVFoundation
import UIKit

/// Camera: live preview inside the screen, wheel zoom, prev/next cycles the
/// aspect ratio, hold flips the lens, center captures, MENU opens options.
struct CameraScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    @State private var optionsOpen = false
    @State private var optionsSelection = 0
    @State private var flashOverlay = false
    @State private var savedOverlay = false

    private var aspect: (label: String, value: CGFloat) {
        AppSettings.aspectRatios[min(settings.cameraAspectIndex, AppSettings.aspectRatios.count - 1)]
    }

    var body: some View {
        ZStack {
            if model.camera.deviceAvailable {
                CameraSessionPreview(session: model.camera.session, aspect: aspect.value)
                controlHints
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
                    Text("Saved to Photos")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(.bottom, 34)
                }
                .transition(.opacity)
            }
        }
        .onReceive(model.controlBus) { handle($0) }
        .onAppear {
            model.transportClaimedByScreen = true
            model.camera.configureIfNeeded()
            model.camera.start()
        }
        .onDisappear {
            model.transportClaimedByScreen = false
            model.camera.stop()
        }
    }

    // MARK: Overlays

    private var controlHints: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(aspect.label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                    .padding(.trailing, 8)
                    .padding(.top, 4)
            }
            Spacer()
            HStack(spacing: 10) {
                hint("Center", "Capture")
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

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9.5, weight: .bold))
            Text(action)
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(0.92))
    }

    private var flashModes: [(String, AVCaptureDevice.FlashMode)] {
        [("Off", .off), ("On", .on), ("Auto", .auto)]
    }

    private var optionsItems: [MenuItem] {
        [
            MenuItem(id: "flash", title: "Flash", detail: flashModes[min(settings.cameraFlash, 2)].0, showsChevron: false),
            MenuItem(id: "back", title: "Back Camera", detail: settings.cameraFront ? nil : "✓", showsChevron: false),
            MenuItem(id: "front", title: "Selfie Camera", detail: settings.cameraFront ? "✓" : nil, showsChevron: false),
            MenuItem(id: "ratio", title: "Aspect Ratio", detail: aspect.label, showsChevron: false),
        ]
    }

    private var optionsPanel: some View {
        ModalPanel(title: "Camera Options", onClose: { optionsOpen = false }) {
            VStack(spacing: 0) {
                ForEach(Array(optionsItems.enumerated()), id: \.element.id) { i, item in
                    MenuRow(item: item, selected: optionsSelection == i)
                        .frame(height: 30.5)
                    Divider().background(Color.black.opacity(0.10))
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Input

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
            } else {
                capturePhoto()
            }
        case .menu:
            optionsOpen.toggle()
            optionsSelection = 0
        case .prev:
            if !optionsOpen {
                settings.cameraAspectIndex = (settings.cameraAspectIndex + AppSettings.aspectRatios.count - 1) % AppSettings.aspectRatios.count
            }
        case .next:
            if !optionsOpen {
                settings.cameraAspectIndex = (settings.cameraAspectIndex + 1) % AppSettings.aspectRatios.count
            }
        case .prevHold, .nextHold:
            if !optionsOpen {
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

    private func activateOption() {
        let id = optionsItems[min(optionsSelection, optionsItems.count - 1)].id
        switch id {
        case "flash":
            settings.cameraFlash = (settings.cameraFlash + 1) % 3
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

    private func capturePhoto() {
        let flash = flashModes[min(settings.cameraFlash, 2)].1
        withAnimation(.easeOut(duration: 0.06)) { flashOverlay = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeIn(duration: 0.18)) { flashOverlay = false }
        }

        Task {
            guard let raw = await model.camera.capture(flashMode: flash) else { return }
            let cropped = CameraCapture.crop(raw, toRatio: aspect.value)
            do {
                try await model.photos.saveToLibrary(cropped)
                withAnimation(.easeOut(duration: 0.2)) { savedOverlay = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeIn(duration: 0.3)) { savedOverlay = false }
                }
            } catch {
                // Saving failed (likely missing photo permission); photo lost silently.
            }
        }
    }
}

/// AVCaptureVideoPreviewLayer host, aspect-cropped to the current ratio.
private struct CameraSessionPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let aspect: CGFloat

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
