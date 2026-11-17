import Foundation
import AVFoundation
import UIKit
import SwiftUI
import Photos

/// AVCaptureSession wrapper: lens switching, zoom, flash, aspect-cropped
/// capture, movie recording, photo effects. Configuration happens off-main
/// on a serial queue.
@Observable
final class CameraModel: NSObject {
    /// The shared capture session: the active lens is its input, the
    /// photo/movie outputs hang off it, and the preview layer renders it.
    /// All touching of it goes through `sessionQueue`.
    /// Concept: AVCaptureSession → docs/concepts/avfoundation-camera.md
    let session = AVCaptureSession()

    /// Still-photo output used by `capture(flashMode:)`.
    private let photoOutput = AVCapturePhotoOutput()
    /// Video output; records to a temporary .mov and is attached to the
    /// session only while video mode is on (the preset swaps with it).
    private let movieOutput = AVCaptureMovieFileOutput()
    /// Serial queue owning ALL session work: configuration, start/stop,
    /// zoom, and capture setup. Two reasons to serialize: AVCaptureSession
    /// is not thread-safe, and `startRunning()` blocks for a long time —
    /// funneling everything through one queue keeps both off the main
    /// thread while guaranteeing configure → start ordering.
    /// Concept: serial DispatchQueue → docs/concepts/dispatch-queues.md
    private let sessionQueue = DispatchQueue(label: "camera.session")
    /// The current lens's input; removed and replaced when the lens flips.
    private var videoInput: AVCaptureDeviceInput?
    /// Resume closure for the in-flight still capture. It is stored on
    /// the model (AVCapturePhotoSettings can't carry context through the
    /// delegate), set on the session queue, and consumed exactly once by
    /// the photo delegate — on main.
    private var captureCompletion: ((UIImage?) -> Void)?
    /// Callback stashed by `startRecording`; fired exactly once by the
    /// file delegate when the clip finishes (Bool = saved successfully).
    private var recordingCompletion: ((Bool) -> Void)?

    /// True once `configureSession` has succeeded; `configureIfNeeded`
    /// uses it to run first-time setup exactly once.
    private(set) var configured = false
    /// True when the front (selfie) lens is the active input.
    private(set) var isFront = false
    /// Current zoom factor, 1…maxZoom; wheel steps it via `bumpZoom`.
    private(set) var zoom: CGFloat = 1
    /// Zoom ceiling from the active format's `videoMaxZoomFactor`, capped
    /// at 16; recomputed on reconfigure because lenses differ.
    private(set) var maxZoom: CGFloat = 8
    /// The most recent captured still, published for review UIs; set on
    /// main by the photo delegate.
    private(set) var lastImage: UIImage?
    /// No camera hardware (e.g. Simulator).
    private(set) var deviceAvailable = true
    /// Photo or video mode.
    private(set) var videoMode = false
    private(set) var isRecording = false
    private(set) var recordingSeconds: Int = 0
    /// Photos: effects are applied to the saved image; video saves clean.
    var effect: CameraEffect = .none

    /// 1 s ticker behind `recordingSeconds`. Scheduled on the main run
    /// loop because the session queue has no run loop; invalidated on stop.
    private var recordTimer: Timer?

    /// First-time setup: configures the back lens once on the session
    /// queue; a no-op after that, so it is safe to call on every appear.
    func configureIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, !self.configured else { return }
            self.configureSession(isFront: false)
        }
    }

    /// Starts the session on the session queue. `startRunning()` blocks
    /// until the pipeline is up — keeping it off the main thread is half
    /// of what `sessionQueue` exists for.
    func start() {
        sessionQueue.async { [weak self] in
            guard let self, self.configured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    /// Stops the session off-main when the screen disappears, releasing
    /// the camera so other apps can claim it.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: Setup

    /// Picks the camera for one side, preferring the most capable
    /// hardware: DiscoverySession returns matches in `deviceTypes` order,
    /// so `.first` yields Triple → Dual → DualWide → plain WideAngle,
    /// whichever exists first.
    /// - Parameter front: True for the selfie camera.
    /// - Returns: The best device at that position, or nil (Simulator).
    private func bestDevice(front: Bool) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video, position: front ? .front : .back
        )
        return discovery.devices.first
    }

    /// Rebuilds the session for a lens flip or mode switch. Must already
    /// run on `sessionQueue` — every caller hops there first.
    ///
    /// `beginConfiguration`/`commitConfiguration` bracket the swap so the
    /// preview doesn't tear while inputs and outputs churn. The preset
    /// follows the mode (.photo for stills, .high for video); the old
    /// lens input is removed and the new one added; the movie output is
    /// attached only in video mode. Zoom resets to 1 (a new lens must
    /// not inherit the old factor) and `maxZoom` comes from the new
    /// device, capped at 16. With no camera hardware (Simulator) the
    /// method bails out early and leaves `deviceAvailable` false, which
    /// the screen turns into a friendly prompt instead of a crash.
    /// - Parameter isFront: True to build around the selfie lens.
    /// Concept: session configuration → docs/concepts/avfoundation-camera.md
    private func configureSession(isFront: Bool) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = videoMode ? .high : .photo

        if let existing = videoInput {
            session.removeInput(existing)
            videoInput = nil
        }

        guard let device = bestDevice(front: isFront),
              let input = try? AVCaptureDeviceInput(device: device) else {
            deviceAvailable = bestDevice(front: isFront) != nil
            return
        }
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        videoInput = input
        self.isFront = isFront

        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if videoMode, !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        } else if !videoMode, session.outputs.contains(movieOutput) {
            session.removeOutput(movieOutput)
        }

        zoom = 1
        try? device.lockForConfiguration()
        device.videoZoomFactor = 1
        device.unlockForConfiguration()
        let deviceMax = min(device.activeFormat.videoMaxZoomFactor, 16)
        maxZoom = max(1, deviceMax)
        configured = true
    }

    /// Switches lenses; runs on the session queue.
    func setFront(_ front: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(isFront: front)
        }
    }

    /// Toggles photo/video; the flag flips on main so SwiftUI sees it
    /// immediately, the session reconfigures on its queue.
    func setVideoMode(_ on: Bool) {
        if isRecording { stopRecording() }
        videoMode = on
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(isFront: self.isFront)
        }
    }

    // MARK: Zoom

    /// Steps zoom multiplicatively — ×1.10 per detent in, ÷1.10 out —
    /// clamped to 1…maxZoom, and applies it to the hardware under
    /// `lockForConfiguration` (the required handshake for changing
    /// videoZoomFactor). Runs on the session queue.
    /// - Parameter direction: +1 zooms in, -1 zooms out.
    func bumpZoom(_ direction: Int) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let step = 1.10
            let target = direction > 0 ? self.zoom * step : self.zoom / step
            let clamped = min(max(1, target), self.maxZoom)
            self.zoom = clamped
            try? device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        }
    }

    // MARK: Capture

    /// Captures one still photo and awaits the decoded image.
    ///
    /// Bridges AVFoundation's delegate-based API into async/await with a
    /// checked continuation: the resume closure is parked in
    /// `captureCompletion`, the shot is taken, and the delegate resumes
    /// the continuation exactly once (nil on failure) — so the await can
    /// neither hang nor double-resume.
    /// - Parameter flashMode: Flash setting for this shot.
    /// - Returns: The captured image, or nil if capture or decoding failed.
    /// Concept: withCheckedContinuation → docs/concepts/swift-async-await.md
    func capture(flashMode: AVCaptureDevice.FlashMode) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.captureCompletion = continuation.resume
                let settings = AVCapturePhotoSettings()
                settings.flashMode = flashMode
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: Recording

    /// Starts recording to a temp file; completion fires on stop with success.
    func startRecording(onFinish: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, !self.isRecording else {
                onFinish(false)
                return
            }
            self.recordingCompletion = onFinish
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("REC-\(Int(Date().timeIntervalSince1970)).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            self.isRecording = true
            // Timer must live on a runloop — the session queue has none.
            DispatchQueue.main.async {
                self.recordingSeconds = 0
                self.recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    self.recordingSeconds += 1
                }
            }
        }
    }

    /// Stops an in-flight recording by hopping to the session queue; the
    /// file delegate saves the clip and fires the completion.
    func stopRecording() {
        sessionQueue.async { [weak self] in
            self?.stopRecordingInternal()
        }
    }

    /// Stop path that already runs on `sessionQueue`: invalidate the
    /// elapsed timer, then hand off to `movieOutput.stopRecording()` —
    /// the delegate callback finishes the sequence.
    private func stopRecordingInternal() {
        guard isRecording else { return }
        recordTimer?.invalidate()
        recordTimer = nil
        movieOutput.stopRecording()
    }
}

/// Photo effects for the camera (applied to the saved photo).
enum CameraEffect: String, CaseIterable {
    case none = "None"
    case mono = "Mono"
    case sepia = "Sepia"
    case vivid = "Vivid"
    case warm = "Warm"
    case cool = "Cool"

    /// SwiftUI preview approximations (applied live on the preview layer).
    var saturation: Double {
        switch self {
        case .mono: return 0
        case .vivid: return 1.6
        default: return 1
        }
    }
    /// Preview hue-rotation degrees for the Warm (-18) / Cool (22) looks.
    var hueRotation: Double {
        switch self {
        case .warm: return -18
        case .cool: return 22
        default: return 0
        }
    }
    /// Translucent tint laid over the preview to fake Sepia/Warm/Cool
    /// (the matching CoreImage filter runs only on capture); nil when
    /// the effect needs no overlay.
    var overlayColor: Color? {
        switch self {
        case .sepia: return Color(red: 0.98, green: 0.85, blue: 0.6).opacity(0.18)
        case .warm: return Color(red: 1.0, green: 0.78, blue: 0.55).opacity(0.12)
        case .cool: return Color(red: 0.62, green: 0.78, blue: 1.0).opacity(0.12)
        default: return nil
        }
    }

    /// CoreImage filter applied to the captured photo.
    func apply(to image: UIImage) -> UIImage {
        guard self != .none, let ci = CIImage(image: image) else { return image }
        let f: CIFilter
        switch self {
        case .none: return image
        case .mono: f = CIFilter(name: "CIPhotoEffectMono")!
        case .sepia: f = CIFilter(name: "CISepiaTone")!
        case .vivid: f = CIFilter(name: "CIVibrance")!
        case .warm: f = CIFilter(name: "CIPhotoEffectChrome")!
        case .cool: f = CIFilter(name: "CIPhotoEffectProcess")!
        }
        f.setValue(ci, forKey: kCIInputImageKey)
        if self == .sepia { f.setValue(0.8, forKey: kCIInputIntensityKey) }
        if self == .vivid { f.setValue(0.9, forKey: "inputAmount") }
        guard let out = f.outputImage,
              let cg = CIContext().createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// Movie-recording completion: clears recording state, saves the clip to
/// the camera roll, and resolves the pending `startRecording` callback.
extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    /// Called by AVFoundation (on its own queue) once the .mov is sealed:
    /// success is derived from the error, a good clip goes to the photo
    /// album, and the stored completion fires on main because SwiftUI
    /// state and UI work must happen there.
    /// - Parameters:
    ///   - outputFileURL: The finished temporary recording.
    ///   - error: Non-nil when recording failed; the file is discarded.
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        isRecording = false
        let completion = recordingCompletion
        recordingCompletion = nil
        let ok = error == nil
        if ok {
            UISaveVideoAtPathToSavedPhotosAlbum(outputFileURL.path, nil, nil, nil)
        }
        DispatchQueue.main.async { completion?(ok) }
    }
}

/// Still-capture completion: decodes the photo and resolves the pending
/// `capture(flashMode:)` continuation.
extension CameraModel: AVCapturePhotoCaptureDelegate {
    /// Called by AVFoundation when the shot is processed. Extracts the
    /// image bytes (`fileDataRepresentation` → data → UIImage), publishes
    /// `lastImage`, and resumes the parked continuation on main — or
    /// resumes it with nil on any failure so the caller never hangs.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let completion = captureCompletion
        captureCompletion = nil
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion?(nil)
            return
        }
        DispatchQueue.main.async {
            self.lastImage = image
            completion?(image)
        }
    }
}

/// Namespace for capture post-processing helpers — static only, never
/// instantiated (a case-less enum is Swift's idiom for namespacing).
enum CameraCapture {
    /// Center-crops a captured image to an aspect ratio (w/h).
    static func crop(_ image: UIImage, toRatio ratio: CGFloat) -> UIImage {
        let size = image.size
        let current = size.width / size.height
        var target = size
        if current > ratio {
            target.width = size.height * ratio
        } else {
            target.height = size.width / ratio
        }
        let origin = CGPoint(x: (size.width - target.width) / 2, y: (size.height - target.height) / 2)
        let rect = CGRect(origin: origin, size: target)
        guard let cgImage = image.cgImage?.cropping(to: rect) else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
