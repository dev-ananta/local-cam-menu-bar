# LocalCam — macOS Menu-Bar Webcam Streamer

LocalCam is a native macOS menu-bar application that captures webcam frames with AVFoundation and streams them to Android over a local-network WebSocket.

## What it does
- Runs as a menu-bar utility (`LSUIElement`) without a normal Dock app icon.
- Lets you start/stop streaming from the menu bar.
- Shows:
  - camera availability
  - active streaming status
  - Android client connection count
  - selected camera
  - current endpoint (`ws://<LAN-IP>:8765/`)
  - latest runtime error/disconnection event
- Supports choosing among detected cameras, preferring external USB webcams by default.

## Protocol contract (compatible with `dev-ananta/webcam-receiver`)
- Transport: WebSocket over trusted LAN (`ws://`)
- Port: `8765`
- Path: `/`
- Payload: each **binary** WebSocket message is one complete JPEG frame
- Text messages: optional for status/errors only (Android companion currently ignores text frames)

## Requirements
- macOS 13+
- Xcode 15+
- Trusted LAN shared with the Android device

## Build and run locally
1. Open `/home/runner/work/local-cam-menu-bar/local-cam-menu-bar/LocalCam.xcodeproj` in Xcode.
2. Select the `LocalCam` scheme.
3. Build and run on macOS.
4. Grant Camera permission when prompted.
5. Click the menu-bar camera icon and choose **Start Streaming**.
6. On Android, connect to `ws://<shown-LAN-IP>:8765/`.

## Camera permission behavior
LocalCam uses standard macOS camera consent flow.
- If denied, LocalCam shows an actionable error and you must enable access in:
  - **System Settings → Privacy & Security → Camera**
- If restricted by policy, LocalCam reports restriction state.

## Using the menu-bar app
- **Start Streaming / Stop Streaming**: controls capture + WebSocket listener lifecycle.
- **Refresh Cameras**: re-scan camera devices.
- **Choose Camera**: pick a specific input camera.
- **Check Camera Permission**: inspect current permission state.
- **Quit LocalCam**: cleanly shuts down capture/network.

## Networking and firewall
- Ensure Mac and Android are on the same trusted Wi-Fi/LAN.
- Allow inbound TCP 8765 in macOS firewall when prompted.
- LocalCam reports the currently detected LAN IP, but if unavailable it will still listen on the configured port.

## Security limitations
- Connection is unencrypted `ws://` (no TLS).
- No authentication/pairing is enforced.
- Use only on trusted private networks.
- Do not port-forward this service to the public internet.

## CI/CD workflow
GitHub Actions workflow:
- runs on pushes and pull requests
- selects a supported Xcode on macOS runner
- builds the Xcode project with `xcodebuild`
- runs unit tests with `swift test`
- packages:
  - zipped `.app` artifact (`LocalCam-app`)
  - `.dmg` artifact (`LocalCam-dmg`)

Unsigned development artifacts are produced when signing secrets are not configured.

## Optional signing/notarization secrets
- `SIGNING_CERTIFICATE_P12`
- `SIGNING_CERTIFICATE_PASSWORD`
- `NOTARIZATION_APPLE_ID`
- `NOTARIZATION_PASSWORD`
- `NOTARIZATION_TEAM_ID`

If present, the workflow signs and validates the app, then notarizes/staples the DMG.

## Troubleshooting
- **No video on Android**:
  - confirm LocalCam shows `Streaming: Active`
  - confirm endpoint IP matches Mac LAN IP
  - verify Android uses that IP with port `8765`
  - check both devices are on same subnet/LAN
- **Connection failed**:
  - allow inbound connection in firewall
  - restart streaming in LocalCam
  - reconnect Android client
- **Camera unavailable**:
  - reconnect USB camera
  - choose another camera from **Choose Camera**
  - use **Refresh Cameras**
