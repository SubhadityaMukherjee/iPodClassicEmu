import Foundation
import AVFoundation
import UIKit
import Photos

/// AVCaptureSession wrapper: lens switching, zoom, flash, aspect-cropped
/// capture. Configuration happens off-main on a serial queue.
@Observable
final class CameraModel: NSObject {
    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var videoInput: AVCaptureDeviceInput?
    private var captureCompletion: ((UIImage?) -> Void)?

    private(set) var configured = false
    private(set) var isFront = false
    private(set) var zoom: CGFloat = 1
    private(set) var maxZoom: CGFloat = 8
    private(set) var lastImage: UIImage?
    /// No camera hardware (e.g. Simulator).
    private(set) var deviceAvailable = true

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
        session.sessionPreset = .photo

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
        await withCheckedContinuation { continuation in
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
