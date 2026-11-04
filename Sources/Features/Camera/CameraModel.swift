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
    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var videoInput: AVCaptureDeviceInput?
    private var captureCompletion: ((UIImage?) -> Void)?
    private var recordingCompletion: ((Bool) -> Void)?

    private(set) var configured = false
    private(set) var isFront = false
    private(set) var zoom: CGFloat = 1
    private(set) var maxZoom: CGFloat = 8
    private(set) var lastImage: UIImage?
    /// No camera hardware (e.g. Simulator).
    private(set) var deviceAvailable = true
    /// Photo or video mode.
    private(set) var videoMode = false
    private(set) var isRecording = false
    private(set) var recordingSeconds: Int = 0
    /// Photos: effects are applied to the saved image; video saves clean.
    var effect: CameraEffect = .none

    private var recordTimer: Timer?

    func configureIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, !self.configured else { return }
            self.configureSession(isFront: false)
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, self.configured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: Setup

    private func bestDevice(front: Bool) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video, position: front ? .front : .back
        )
        return discovery.devices.first
    }

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

    /// Toggles photo/video; reconfigures the session.
    func setVideoMode(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.videoMode != on else { return }
            if self.isRecording { self.stopRecordingInternal() }
            self.videoMode = on
            self.configureSession(isFront: self.isFront)
        }
    }

    // MARK: Zoom

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
            DispatchQueue.main.async { self.recordingSeconds = 0 }
            self.recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                DispatchQueue.main.async { self.recordingSeconds += 1 }
            }
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            self?.stopRecordingInternal()
        }
    }

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
    var hueRotation: Double {
        switch self {
        case .warm: return -18
        case .cool: return 22
        default: return 0
        }
    }
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

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
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

extension CameraModel: AVCapturePhotoCaptureDelegate {
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
