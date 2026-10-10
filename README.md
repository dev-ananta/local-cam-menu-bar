# LocalCam — macOS Menu-Bar Webcam Stream

A minimal SwiftUI/AppKit menu-bar app that captures a webcam with AVFoundation and streams JPEG frames over a local-network WebSocket. It intentionally shows a visible menu-bar status and requires the user to start/stop streaming.

## Requirements
- macOS 13+
- Xcode 15+
- For the CI workflow: GitHub-hosted `macos-latest` runner
- The receiving device must be on a trusted LAN and connect to `ws://<Mac-LAN-IP>:8765/`

## Build locally
1. Open `LocalCam.xcodeproj` in Xcode.
2. Select the `LocalCam` scheme and a macOS destination.
3. Build and run. On first use, approve Camera access in System Settings.
4. Click the camera icon in the menu bar and choose **Start Streaming**.
5. Find the Mac's LAN IP in System Settings → Network. Connect a WebSocket client to `ws://<IP>:8765/`.
   Each WebSocket binary message is one JPEG image. This starter sends frames at a limited rate/resolution to reduce bandwidth.

This is a starter implementation, not a hardened production streaming service. It has no authentication or TLS. Use only on a trusted network; do not port-forward it. For enterprise use, add pairing/authentication, TLS, client allowlisting, rate limiting, and security review. A companion client is not included.

## Camera and MDM privacy limitations
macOS privacy controls are intentionally enforced by the operating system. **Do not assume an MDM profile can silently pre-approve Camera or Screen Recording for this app.** Apple restricts management of these protected user-consent decisions, and behavior varies by macOS version and payload/service. Validate against Apple's current deployment documentation and your target OS; plan for a user approval flow where required. This app does not capture the screen and does not install a system extension, so neither Screen Recording nor System Extension approval is needed for its current functionality.

The included `Deployment/EnterpriseProfile.mobileconfig` is a template for a managed System Extensions policy only. It does not grant camera access or screen-recording access. Replace the example Team ID and bundle ID before deployment and have your MDM administrator validate the payload.

## Signing / notarization
Set the following GitHub repository secrets:
- `SIGNING_CERTIFICATE_P12` — base64-encoded Developer ID Application `.p12`
- `SIGNING_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `NOTARIZATION_APPLE_ID`
- `NOTARIZATION_PASSWORD` — app-specific password
- `NOTARIZATION_TEAM_ID`

The workflow signs the app if the certificate secret exists, submits the DMG for notarization when all notarization secrets are set, staples the ticket, then uploads the DMG. Without secrets, it still builds and packages an unsigned artifact for testing; macOS will show trust warnings.

## Build output
GitHub Actions artifact: `LocalCam-dmg`, containing `LocalCam.dmg`.
