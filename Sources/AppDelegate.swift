import AppKit
import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let camera = CameraStreamer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "web.camera", accessibilityDescription: "LocalCam")
        statusItem.button?.toolTip = "LocalCam — webcam streaming"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: camera.isStreaming ? "Streaming on port 8765" : "Camera not streaming", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: camera.isStreaming ? "Stop Streaming" : "Start Streaming", action: #selector(toggleStreaming), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
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
        if camera.isStreaming {
            camera.stop()
            statusItem.button?.image = NSImage(systemSymbolName: "web.camera", accessibilityDescription: "LocalCam")
        } else {
            camera.start { [weak self] success, message in
                DispatchQueue.main.async {
                    if !success {
                        let alert = NSAlert()
                        alert.messageText = "Unable to start camera"
                        alert.informativeText = message
                        alert.runModal()
                    }
                    self?.statusItem.button?.image = NSImage(
                        systemSymbolName: success ? "web.camera.fill" : "web.camera",
                        accessibilityDescription: "LocalCam"
                    )
                    self?.rebuildMenu()
                }
            }
        }
        rebuildMenu()
    }

    @objc private func checkPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let message: String
        switch status {
        case .authorized: message = "Camera access is allowed."
        case .notDetermined: message = "Camera access has not been requested yet. Choose Start Streaming to request it."
        case .denied: message = "Camera access is denied. Enable it in System Settings → Privacy & Security → Camera."
        case .restricted: message = "Camera access is restricted by system or management policy."
        @unknown default: message = "Camera permission status is unknown."
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
}
