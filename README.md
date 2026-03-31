# Homecast Community Edition

Control your Apple HomeKit smart home from any browser, REST API, or AI assistant — running entirely on your Mac with no cloud dependency.

<p>
  <a href="https://apps.apple.com/us/app/homecast-app/id6759559232?platform=mac"><img src="https://img.shields.io/badge/Mac_App_Store-Download-blue?logo=apple&logoColor=white" alt="Mac App Store"></a>
  <a href="https://homecast.cloud"><img src="https://img.shields.io/badge/Homecast_Cloud-homecast.cloud-blue" alt="Homecast Cloud"></a>
  <a href="https://docs.homecast.cloud"><img src="https://img.shields.io/badge/Docs-docs.homecast.cloud-blue" alt="Documentation"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License"></a>
</p>

## Install

### Option 1: Mac App Store (Easiest)

Download from the [Mac App Store](https://apps.apple.com/us/app/homecast-app/id6759559232?platform=mac). Launch the app, select **Community** on the mode selector, and you're ready to go.

### Option 2: Build from Source

**Prerequisites:** macOS 13+, Xcode 15+, Node.js 18+

```bash
# Clone both repos
git clone https://github.com/parob/homecast.git
git clone https://github.com/parob/homecast-web.git homecast/app-web

# Build the web app
cd homecast/app-web
npm install && npm run build

# Bundle into the Mac app
cd ../app-ios-macos
./scripts/bundle-web-app.sh

# Open in Xcode and build
open Homecast.xcodeproj
# Build for: My Mac (Mac Catalyst)
```

> **Note:** HomeKit requires a valid Apple Developer account with the `com.apple.developer.homekit` entitlement. App Store distribution is required — Developer ID builds won't work.

## What You Get

- **Control from any browser** — open `http://your-mac.local:5656` on your phone or tablet
- **REST API** — `GET /rest/homes`, `GET /rest/accessories`, `POST /rest/state`
- **MCP for AI assistants** — connect Claude, ChatGPT, or any MCP client to `/mcp`
- **Real-time updates** — device state changes appear instantly on all connected clients
- **Sharing** — share homes, rooms, or accessories via links with optional passcode
- **Collections** — organize devices into custom groups
- **Automations** — view and manage HomeKit automations
- **No cloud, no account** — everything runs locally on your Mac

## How It Works

```
Your Mac (Homecast App)
├── HTTP server (port 5656) — web UI + REST API + MCP
├── WebSocket server (port 5657) — real-time updates
├── WKWebView — bundled web app with HomeKit bridge
└── HomeKit Framework — your smart home devices

Other devices connect to your Mac's IP:
  Phone browser  → http://your-mac.local:5656
  AI assistant   → http://your-mac.local:5656/mcp
  curl/scripts   → http://your-mac.local:5656/rest/accessories
```

## API

```bash
# List homes
curl http://your-mac.local:5656/rest/homes

# List accessories
curl http://your-mac.local:5656/rest/accessories?home=HOME_ID

# Turn on a light
curl -X POST http://your-mac.local:5656/rest/state \
  -H "Content-Type: application/json" \
  -d '{"ACCESSORY_ID": {"switch": {"power_state": 1}}}'

# List scenes
curl http://your-mac.local:5656/rest/scenes?home=HOME_ID
```

### MCP (AI Assistants)

Point your MCP client at `http://your-mac.local:5656/mcp`.

Available tools: `list_homes`, `list_rooms`, `list_accessories`, `get_accessory`, `set_characteristic`, `set_state`, `list_scenes`, `execute_scene`, `list_service_groups`

## Remote Access

Community Edition works on your local network. For remote access, use a tunnel:

- **[Tailscale](https://tailscale.com)** (recommended) — zero-config VPN, valid HTTPS certs
- **[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)** — free, requires Cloudflare account
- **Port forwarding** — forward port 5656 on your router

Or use [Homecast Cloud](https://homecast.cloud) for built-in remote access, cloud sync, and managed relays.

## Project Structure

```
app-ios-macos/              Mac app (Swift, Mac Catalyst)
├── Sources/App/            App lifecycle, WebView, mode selector
├── Sources/HomeKit/        HomeKit bridge and manager
├── Sources/Server/         Local HTTP + WebSocket server
├── Sources/MenuBarPlugin/  macOS menu bar UI
└── scripts/                Build helpers

app-web/                    Web app (separate repo: parob/homecast-web)
├── src/server/             Community server modules
├── src/relay/              HomeKit bridge (JS side)
├── src/components/         UI components
└── src/pages/              Page components

app-android-windows-linux/  Tauri wrapper (Android, Windows, Linux)
```

## Documentation

Full documentation at **[docs.homecast.cloud](https://docs.homecast.cloud)**.

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

## License

[MIT](LICENSE)
