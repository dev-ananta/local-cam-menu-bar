import AVFoundation
import AppKit
import Network
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Captures camera frames and publishes JPEG images as WebSocket binary messages.
/// This starter intentionally has no authentication/TLS; use only on a trusted LAN.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "localcam.capture")
    private let networkQueue = DispatchQueue(label: "localcam.network")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private var lastFrameTime = Date.distantPast
    private let frameInterval: TimeInterval = 0.12 // ~8 fps
    private(set) var isStreaming = false

    func start(completion: @escaping (Bool, String) -> Void) {
        guard !isStreaming else { completion(true, "Already streaming."); return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized {
            configureAndStart(completion: completion)
        } else if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                guard granted else { completion(false, "Camera access was not granted."); return }
                self.configureAndStart(completion: completion)
            }
        } else {
            completion(false, status == .denied
                ? "Camera access is denied. Enable it in System Settings → Privacy & Security → Camera."
                : "Camera access is restricted by macOS or management policy.")
        }
    }

    private func configureAndStart(completion: @escaping (Bool, String) -> Void) {
        captureQueue.async {
            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .vga640x480
                defer { self.session.commitConfiguration() }

                // Prefer an external camera when one is available, then fall back to the system default.
                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.external, .builtInWideAngleCamera],
                    mediaType: .video,
                    position: .unspecified
                )
                let device = discovery.devices.first(where: { $0.deviceType == .external })
                    ?? AVCaptureDevice.default(for: .video)
                guard let device else { completion(false, "No compatible webcam was found."); return }

                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    completion(false, "Could not add the selected webcam to the capture session."); return
                }
                self.session.inputs.forEach(self.session.removeInput)
                self.session.addInput(input)

                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.captureQueue)
                guard self.session.canAddOutput(output) else {
                    completion(false, "Could not configure video output."); return
                }
                self.session.outputs.forEach(self.session.removeOutput)
                self.session.addOutput(output)

                self.startListener { success, message in
                    guard success else { completion(false, message); return }
                    self.session.startRunning()
                    self.isStreaming = true
                    completion(true, "Streaming on port 8765.")
                }
            } catch {
                completion(false, error.localizedDescription)
            }
        }
    }

    func stop() {
        captureQueue.async {
            self.session.stopRunning()
            self.listener?.cancel()
            self.listener = nil
            self.lock.lock()
            let connections = Array(self.clients.values)
            self.clients.removeAll()
            self.lock.unlock()
            connections.forEach { $0.cancel() }
            self.isStreaming = false
        }
    }

    private func startListener(completion: @escaping (Bool, String) -> Void) {
        do {
            let parameters = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 8765)!)
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        self.lock.lock()
                        self.clients[ObjectIdentifier(connection)] = connection
                        self.lock.unlock()
                        self.receiveLoop(connection)
                    } else if case .failed = state {
                        self.removeClient(connection)
                    } else if case .cancelled = state {
                        self.removeClient(connection)
                    }
                }
                connection.start(queue: self.networkQueue)
            }
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready: completion(true, "WebSocket server ready on port 8765.")
                case .failed(let error): completion(false, "Could not start local server: \(error.localizedDescription)")
                default: break
                }
            }
            self.listener = newListener
            newListener.start(queue: networkQueue)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete { self.removeClient(connection); return }
            self.receiveLoop(connection)
        }
    }

    private func removeClient(_ connection: NWConnection) {
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let jpeg = makeJPEG(pixelBuffer) else { return }

        lock.lock()
        let activeClients = Array(clients.values)
        lock.unlock()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "jpeg-frame", metadata: [metadata])
        for client in activeClients {
            client.send(content: jpeg, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    private func makeJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
