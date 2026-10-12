import AVFoundation
import Foundation
import Network
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

struct CameraOption: Equatable {
    let uniqueID: String
    let name: String
    let isExternal: Bool
}

struct StreamStatus {
    var isStreaming: Bool = false
    var isCameraAvailable: Bool = false
    var cameras: [CameraOption] = []
    var selectedCameraID: String?
    var selectedCameraName: String?
    var connectedClientCount: Int = 0
    var listeningPort: UInt16?
    var lanAddress: String?
    var lastError: String?
}

/// Captures camera frames and publishes JPEG images as WebSocket binary messages.
/// This app intentionally uses unencrypted ws:// on trusted LAN only.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "localcam.capture")
    private let networkQueue = DispatchQueue(label: "localcam.network")
    private let stateLock = NSLock()
    private let frameBuffer = LatestFrameBuffer()
    private let jpegContext = CIContext()

    private struct ClientState {
        let connection: NWConnection
        var sendInFlight: Bool
    }

    private var listener: NWListener?
    private var senderTimer: DispatchSourceTimer?
    private var clients: [ObjectIdentifier: ClientState] = [:]

    private var lastEncodeTime = Date.distantPast
    private var selectedCameraID: String?
    private var currentDeviceID: String?
    private var didPublishOversizeFrameError = false
    private var hasStartedObservers = false

    private var status = StreamStatus()
    var onStatusChange: ((StreamStatus) -> Void)?

    override init() {
        super.init()
        installDeviceObserversIfNeeded()
        refreshCameras()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func currentStatus() -> StreamStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return status
    }

    func refreshCameras() {
        captureQueue.async {
            self.refreshCamerasLocked(updateSelectionIfNeeded: true)
            self.publishStatus()
        }
    }

    func selectCamera(uniqueID: String, completion: @escaping (Bool, String) -> Void) {
        captureQueue.async {
            self.selectedCameraID = uniqueID
            self.refreshCamerasLocked(updateSelectionIfNeeded: false)

            guard self.status.isStreaming else {
                self.publishStatus()
                completion(true, "Camera updated.")
                return
            }

            do {
                try self.configureCaptureSessionLocked()
                self.publishStatus()
                completion(true, "Switched camera.")
            } catch {
                let message = "Unable to switch camera: \(error.localizedDescription)"
                self.recordError(message)
                completion(false, message)
            }
        }
    }

    func start(completion: @escaping (Bool, String) -> Void) {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorizationStatus {
        case .authorized:
            configureAndStart(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                guard granted else {
                    completion(false, "Camera access was not granted.")
                    self.recordError("Camera permission denied by user.")
                    return
                }
                self.configureAndStart(completion: completion)
            }
        case .denied:
            let message = "Camera access is denied. Enable it in System Settings → Privacy & Security → Camera."
            recordError(message)
            completion(false, message)
        case .restricted:
            let message = "Camera access is restricted by macOS or management policy."
            recordError(message)
            completion(false, message)
        @unknown default:
            let message = "Unknown camera authorization status."
            recordError(message)
            completion(false, message)
        }
    }

    func stop() {
        captureQueue.async {
            self.stopLocked()
        }
    }

    private func configureAndStart(completion: @escaping (Bool, String) -> Void) {
        captureQueue.async {
            guard !self.status.isStreaming else {
                completion(true, "Already streaming.")
                return
            }

            self.refreshCamerasLocked(updateSelectionIfNeeded: true)
            guard self.status.isCameraAvailable else {
                let message = "No compatible camera is currently available."
                self.recordError(message)
                completion(false, message)
                return
            }

            do {
                try self.configureCaptureSessionLocked()
            } catch {
                let message = "Camera initialization failed: \(error.localizedDescription)"
                self.recordError(message)
                completion(false, message)
                return
            }

            self.startListener { success, message in
                self.captureQueue.async {
                    guard success else {
                        self.recordError(message)
                        completion(false, message)
                        return
                    }

                    self.session.startRunning()
                    self.startFrameSenderLocked()
                    self.status.isStreaming = true
                    self.status.lastError = nil
                    self.status.lanAddress = LANAddressResolver.preferredIPv4Address()
                    self.publishStatus()

                    let endpoint = self.endpointDescriptionLocked()
                    completion(true, "Streaming started on \(endpoint).")
                }
            }
        }
    }

    private func stopLocked() {
        if session.isRunning {
            session.stopRunning()
        }

        stopFrameSenderLocked()
        frameBuffer.clear()
        didPublishOversizeFrameError = false

        listener?.cancel()
        listener = nil

        stateLock.lock()
        let existingConnections = clients.values.map(\.connection)
        clients.removeAll()
        stateLock.unlock()

        existingConnections.forEach { $0.cancel() }

        status.isStreaming = false
        status.connectedClientCount = 0
        status.listeningPort = nil
        status.lanAddress = nil
        status.lastError = nil
        publishStatus()
    }

    private func configureCaptureSessionLocked() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .vga640x480

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices
        guard !devices.isEmpty else {
            throw NSError(domain: "LocalCam", code: 1001, userInfo: [NSLocalizedDescriptionKey: "No camera devices found"])
        }

        let selectedDevice: AVCaptureDevice
        if let selectedCameraID,
           let matched = devices.first(where: { $0.uniqueID == selectedCameraID }) {
            selectedDevice = matched
        } else if let external = devices.first(where: { $0.deviceType == .external }) {
            selectedDevice = external
            self.selectedCameraID = external.uniqueID
        } else if let first = devices.first {
            selectedDevice = first
            self.selectedCameraID = first.uniqueID
        } else {
            throw NSError(domain: "LocalCam", code: 1002, userInfo: [NSLocalizedDescriptionKey: "No suitable camera selected"])
        }

        let input = try AVCaptureDeviceInput(device: selectedDevice)

        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else {
            throw NSError(domain: "LocalCam", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Unable to add camera input"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        session.outputs.forEach(session.removeOutput)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "LocalCam", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Unable to add camera output"])
        }
        session.addOutput(output)

        currentDeviceID = selectedDevice.uniqueID
        status.selectedCameraID = selectedDevice.uniqueID
        status.selectedCameraName = selectedDevice.localizedName
    }

    private func startListener(completion: @escaping (Bool, String) -> Void) {
        do {
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true

            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false

            guard let port = NWEndpoint.Port(rawValue: StreamingProtocolSpec.port) else {
                completion(false, "Invalid configured port.")
                return
            }

            let newListener = try NWListener(using: parameters, on: port)
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.registerClient(connection)
                        self.receiveLoop(connection)
                    case .failed(let error):
                        self.removeClient(connection, reason: "Client failed: \(error.localizedDescription)")
                    case .cancelled:
                        self.removeClient(connection, reason: "Client disconnected.")
                    default:
                        break
                    }
                }

                connection.start(queue: self.networkQueue)
            }

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.captureQueue.async {
                        self.status.listeningPort = newListener.port?.rawValue ?? StreamingProtocolSpec.port
                        self.status.lanAddress = LANAddressResolver.preferredIPv4Address()
                        self.publishStatus()
                    }
                    completion(true, "WebSocket server ready.")
                case .failed(let error):
                    completion(false, "Unable to start WebSocket server: \(error.localizedDescription)")
                default:
                    break
                }
            }

            listener = newListener
            newListener.start(queue: networkQueue)
        } catch {
            completion(false, "Unable to start listener: \(error.localizedDescription)")
        }
    }

    private func startFrameSenderLocked() {
        stopFrameSenderLocked()

        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        let interval = StreamingProtocolSpec.frameInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.broadcastLatestFrame()
        }
        senderTimer = timer
        timer.resume()
    }

    private func stopFrameSenderLocked() {
        senderTimer?.cancel()
        senderTimer = nil
    }

    private func broadcastLatestFrame() {
        guard let frame = frameBuffer.takeLatest() else { return }

        stateLock.lock()
        let snapshots = clients.map { ($0.key, $0.value) }
        stateLock.unlock()

        if snapshots.isEmpty { return }

        for (identifier, state) in snapshots {
            if state.sendInFlight { continue }

            markClientSending(identifier: identifier, sending: true)

            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "jpeg-frame", metadata: [metadata])
            state.connection.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.removeClient(state.connection, reason: "Send failed: \(error.localizedDescription)")
                } else {
                    self.markClientSending(identifier: identifier, sending: false)
                }
            })
        }
    }

    private func markClientSending(identifier: ObjectIdentifier, sending: Bool) {
        stateLock.lock()
        if var client = clients[identifier] {
            client.sendInFlight = sending
            clients[identifier] = client
        }
        stateLock.unlock()
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.removeClient(connection, reason: "Client receive error: \(error.localizedDescription)")
                return
            }

            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                self.removeClient(connection, reason: "Client closed connection.")
                return
            }

            if data == nil, context == nil {
                self.removeClient(connection, reason: "Client connection ended.")
                return
            }

            self.receiveLoop(connection)
        }
    }

    private func registerClient(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        stateLock.lock()
        clients[identifier] = ClientState(connection: connection, sendInFlight: false)
        let count = clients.count
        stateLock.unlock()

        captureQueue.async {
            self.status.connectedClientCount = count
            self.status.lastError = nil
            self.publishStatus()
        }
    }

    private func removeClient(_ connection: NWConnection, reason: String?) {
        let identifier = ObjectIdentifier(connection)

        stateLock.lock()
        let removed = clients.removeValue(forKey: identifier)
        let count = clients.count
        stateLock.unlock()

        guard removed != nil else { return }

        captureQueue.async {
            self.status.connectedClientCount = count
            if let reason {
                self.status.lastError = reason
            }
            self.publishStatus()
        }
    }

    private func refreshCamerasLocked(updateSelectionIfNeeded: Bool) {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        let cameraOptions = discovery.devices.map {
            CameraOption(uniqueID: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType == .external)
        }
        .sorted { lhs, rhs in
            if lhs.isExternal != rhs.isExternal {
                return lhs.isExternal && !rhs.isExternal
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        status.cameras = cameraOptions
        status.isCameraAvailable = !cameraOptions.isEmpty

        if updateSelectionIfNeeded {
            if let selectedCameraID,
               cameraOptions.contains(where: { $0.uniqueID == selectedCameraID }) {
                status.selectedCameraID = selectedCameraID
                status.selectedCameraName = cameraOptions.first(where: { $0.uniqueID == selectedCameraID })?.name
            } else {
                let fallback = cameraOptions.first
                selectedCameraID = fallback?.uniqueID
                status.selectedCameraID = fallback?.uniqueID
                status.selectedCameraName = fallback?.name
            }
        } else {
            status.selectedCameraName = cameraOptions.first(where: { $0.uniqueID == selectedCameraID })?.name
            status.selectedCameraID = selectedCameraID
        }
    }

    private func recordError(_ message: String) {
        captureQueue.async {
            self.status.lastError = message
            self.publishStatus()
        }
    }

    private func publishStatus() {
        let snapshot = status
        DispatchQueue.main.async {
            self.onStatusChange?(snapshot)
        }
    }

    private func endpointDescriptionLocked() -> String {
        let ip = status.lanAddress ?? "<LAN-IP-unavailable>"
        let port = status.listeningPort ?? StreamingProtocolSpec.port
        return StreamingProtocolSpec.endpointURLString(lanAddress: ip, port: port)
    }

    private func installDeviceObserversIfNeeded() {
        guard !hasStartedObservers else { return }
        hasStartedObservers = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceConnected),
            name: .AVCaptureDeviceWasConnected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceDisconnected),
            name: .AVCaptureDeviceWasDisconnected,
            object: nil
        )
    }

    @objc private func handleDeviceConnected(_ notification: Notification) {
        refreshCameras()
    }

    @objc private func handleDeviceDisconnected(_ notification: Notification) {
        guard let disconnectedDevice = notification.object as? AVCaptureDevice else {
            refreshCameras()
            return
        }

        captureQueue.async {
            self.refreshCamerasLocked(updateSelectionIfNeeded: true)

            if self.status.isStreaming, disconnectedDevice.uniqueID == self.currentDeviceID {
                let message = "Selected camera disconnected. Streaming stopped."
                self.stopLocked()
                self.status.lastError = message
            }

            self.publishStatus()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastEncodeTime) >= StreamingProtocolSpec.frameInterval else { return }
        lastEncodeTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let jpeg = makeJPEG(pixelBuffer) else {
            return
        }

        if jpeg.count > StreamingProtocolSpec.maxJPEGBytes {
            if !didPublishOversizeFrameError {
                didPublishOversizeFrameError = true
                status.lastError = "Dropped oversized frame (> \(StreamingProtocolSpec.maxJPEGBytes) bytes)."
                publishStatus()
            }
            return
        }

        didPublishOversizeFrameError = false
        frameBuffer.replace(with: jpeg, maximumBytes: StreamingProtocolSpec.maxJPEGBytes)
    }

    private func makeJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = jpegContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }

        let properties = [
            kCGImageDestinationLossyCompressionQuality: 0.65
        ] as CFDictionary

        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
