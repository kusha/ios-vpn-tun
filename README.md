# VK Turn Proxy for iOS

An iOS port of [vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy). This app allows you to tunnel WireGuard traffic through VK call TURN servers, which can help bypass certain network restrictions.

## Download

**[Download VKTurnProxy.ipa from Releases](https://github.com/kusha/ios-vpn-tun/releases/latest)**

No need to build from source - grab the pre-built IPA and install via AltStore/Sideloadly.

## Prerequisites

- iPhone or iPad running **iOS 18+**
- macOS with **Xcode** installed (full Xcode.app, not just command line tools)
- **Go 1.25+**
- **XcodeGen** (`brew install xcodegen`)
- **AltStore** or **Sideloadly** for installation

## Building the App

### Option A: GitHub CI (Recommended)

You can build the IPA without installing any local development tools by using GitHub Actions.

1. Push your code to a GitHub repository.
2. The **Build IPA** workflow will start automatically.
3. Download the resulting `.ipa` from the **Actions** tab or the **Releases** page.
4. To create a formal release:
   ```bash
   git tag v1.0.0
   git push --tags
   ```

### Option B: Local Build

If you prefer to build locally on your Mac:

1. Clone the repository.
2. Run the build script:
   ```bash
   ./build.sh
   ```
3. Find your app at `build/VKTurnProxy.ipa`.

## Installing

Since this app is not on the App Store, you must sideload it using a tool like AltStore or Sideloadly.

1. Install **AltStore** on your Mac.
2. Connect your iPhone to your Mac via USB.
3. Open AltStore, go to the "My Apps" tab, and tap the "+" icon.
4. Select `VKTurnProxy.ipa` to install it.
5. **Note:** If you use a free Apple ID, you must re-sign the app every **7 days** through AltStore.

## Using the App

1. **Configure VK Turn:**
   - Open the **VK Turn** app on your iPhone.
   - Enter your VK call join link.
   - Enter your peer address (the VPS running your [vk-turn-proxy server](https://github.com/cacggghp/vk-turn-proxy)).
   - Tap **Connect**.

2. **Configure WireGuard:**
   - Open the official **WireGuard** app (from the App Store).
   - Create or edit a tunnel configuration.
   - Set the **Endpoint** to `127.0.0.1:9000`.
   - **CRITICAL:** Update **AllowedIPs** to exclude localhost traffic to prevent loops:
     ```
     AllowedIPs = 0.0.0.0/1, 128.0.0.0/1
     ```
   - Save and activate the tunnel.

3. **Keep-Alive:**
   - The VK Turn app must stay in the foreground or remain in your recent apps list.
   - While background audio helps keep the proxy alive, iOS may still kill the process if system resources are low.

## Limitations

- **Process Persistence:** The proxy stops immediately if the app is killed.
- **Sideloading:** Requires re-signing every 7 days with a free Apple ID.
- **Service Support:** No support for Yandex Telemost.
- **API Changes:** VK may change their internal API at any time, which could break the connection flow.

## Credits

Based on the original [vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy) project by cacggghp.
