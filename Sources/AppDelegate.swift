import AVFoundation
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let camera = CameraStreamer()
    private var latestStatus = StreamStatus()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "web.camera", accessibilityDescription: "LocalCam")
        statusItem.button?.toolTip = "LocalCam — webcam streaming"

        camera.onStatusChange = { [weak self] status in
            self?.latestStatus = status
            self?.updateStatusIcon()
            self?.rebuildMenu()
        }

        camera.refreshCameras()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        camera.stop()
    }

    private func updateStatusIcon() {
        let symbol: String
        if latestStatus.isStreaming {
            symbol = latestStatus.connectedClientCount > 0 ? "web.camera.fill" : "web.camera.badge.ellipsis"
        } else {
            symbol = "web.camera"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LocalCam")
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let streamState = latestStatus.isStreaming ? "Active" : "Stopped"
        let streamStatus = NSMenuItem(title: "Streaming: \(streamState)", action: nil, keyEquivalent: "")
        streamStatus.isEnabled = false
        menu.addItem(streamStatus)

        let cameraState = latestStatus.isCameraAvailable ? "Available" : "Unavailable"
        let cameraStatus = NSMenuItem(title: "Camera: \(cameraState)", action: nil, keyEquivalent: "")
        cameraStatus.isEnabled = false
        menu.addItem(cameraStatus)

        let clientStatus = NSMenuItem(
            title: "Android client: \(latestStatus.connectedClientCount > 0 ? "Connected" : "Not connected") (\(latestStatus.connectedClientCount))",
            action: nil,
            keyEquivalent: ""
        )
        clientStatus.isEnabled = false
        menu.addItem(clientStatus)

        let endpointText: String
        if let port = latestStatus.listeningPort,
           let lanAddress = latestStatus.lanAddress {
            endpointText = StreamingProtocolSpec.endpointURLString(lanAddress: lanAddress, port: port)
        } else {
            endpointText = "Not listening"
        }
        let endpointStatus = NSMenuItem(title: "Endpoint: \(endpointText)", action: nil, keyEquivalent: "")
        endpointStatus.isEnabled = false
        menu.addItem(endpointStatus)

        if let selected = latestStatus.selectedCameraName {
            let selectedCameraItem = NSMenuItem(title: "Selected camera: \(selected)", action: nil, keyEquivalent: "")
            selectedCameraItem.isEnabled = false
            menu.addItem(selectedCameraItem)
        }

        if let error = latestStatus.lastError, !error.isEmpty {
            let lastError = NSMenuItem(title: "Last event: \(error)", action: nil, keyEquivalent: "")
            lastError.isEnabled = false
            menu.addItem(lastError)
        }

        menu.addItem(.separator())

        let toggleTitle = latestStatus.isStreaming ? "Stop Streaming" : "Start Streaming"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleStreaming), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let refreshItem = NSMenuItem(title: "Refresh Cameras", action: #selector(refreshCameras), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let cameraMenuRoot = NSMenuItem(title: "Choose Camera", action: nil, keyEquivalent: "")
        let cameraSubmenu = NSMenu()
        if latestStatus.cameras.isEmpty {
            let noCamera = NSMenuItem(title: "No camera devices found", action: nil, keyEquivalent: "")
            noCamera.isEnabled = false
            cameraSubmenu.addItem(noCamera)
        } else {
            for option in latestStatus.cameras {
                let title = option.isExternal ? "\(option.name) (External)" : option.name
                let item = NSMenuItem(title: title, action: #selector(selectCamera(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = option.uniqueID
                item.state = (option.uniqueID == latestStatus.selectedCameraID) ? .on : .off
                cameraSubmenu.addItem(item)
            }
        }
        cameraMenuRoot.submenu = cameraSubmenu
        menu.addItem(cameraMenuRoot)

        let permission = NSMenuItem(title: "Check Camera Permission", action: #selector(checkPermission), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit LocalCam", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleStreaming() {
        if latestStatus.isStreaming {
            camera.stop()
            return
        }

        camera.start { [weak self] success, message in
            DispatchQueue.main.async {
                if !success {
                    self?.presentError(title: "Unable to start streaming", message: message)
                }
            }
        }
    }

    @objc private func refreshCameras() {
        camera.refreshCameras()
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let cameraID = sender.representedObject as? String else { return }
        camera.selectCamera(uniqueID: cameraID) { [weak self] success, message in
            guard !success else { return }
            DispatchQueue.main.async {
                self?.presentError(title: "Unable to switch camera", message: message)
            }
        }
    }

    @objc private func checkPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let message: String
        switch status {
        case .authorized:
            message = "Camera access is allowed."
        case .notDetermined:
            message = "Camera access has not been requested yet. Choose Start Streaming to request it."
        case .denied:
            message = "Camera access is denied. Enable it in System Settings → Privacy & Security → Camera."
        case .restricted:
            message = "Camera access is restricted by system or management policy."
        @unknown default:
            message = "Camera permission status is unknown."
        }
        let alert = NSAlert()
        alert.messageText = "Camera Permission"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func quitApp() {
        camera.stop()
        NSApp.terminate(nil)
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
