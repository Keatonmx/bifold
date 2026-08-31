//
//  DSiCameraFeed.swift
//  Bifold
//
//  Feeds the phone's camera to the emulated DSi cameras: BGRA frames go
//  straight to the bridge, which converts them to the DSi's 640×480 YUY2.
//  Camera 0 (outer) maps to the back camera, camera 1 (inner) to the front.
//

import AVFoundation

final class DSiCameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// BGRA pixels + dimensions, called on the capture queue.
    var onFrame: ((UnsafePointer<UInt32>, Int, Int) -> Void)?

    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "com.redfernsoutpost.bifold.dsicamera")
    private(set) var position: AVCaptureDevice.Position = .unspecified

    func start(front: Bool) {
        let wanted: AVCaptureDevice.Position = front ? .front : .back
        if session != nil, position == wanted { return }
        stop()
        position = wanted
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            self?.queue.async { self?.begin(position: wanted) }
        }
    }

    private func begin(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        session.startRunning()
        self.session = session
    }

    func stop() {
        session?.stopRunning()
        session = nil
        position = .unspecified
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // The bridge wants tightly packed rows; VGA BGRA rows usually are.
        guard bytesPerRow == width * 4 else { return }
        onFrame(base.assumingMemoryBound(to: UInt32.self), width, height)
    }
}
