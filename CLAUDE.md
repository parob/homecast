# Homecast Community Edition

> `AGENTS.md` and `CLAUDE.md` are identical. Keep them in sync.

Homecast connects Apple HomeKit smart home devices to open standards (REST, MCP, WebSocket), enabling remote control, API access, and AI assistant integration.

The Community Edition runs entirely on a Mac — no cloud server needed.

## Project Structure

| Directory | Description |
|-----------|-------------|
| `app-ios-macos/` | Mac app (Swift/SwiftUI, Mac Catalyst) — HomeKit relay + local server |
| `app-android-windows-linux/` | Tauri app wrapper (Android, Windows, Linux) |
| `app-web/` | Web app (React 18/Vite) — runs inside Mac app's WKWebView + served to LAN clients |
| `docs/` | Documentation build output (source in `homecast-cloud/docs/`) |

## How It Works

The Mac app acts as both the HomeKit relay and the server:

```
Your Mac                         LAN / Tunnel
┌──────────────────────┐    ┌──────────────────┐
│ HomeKit Framework    │    │ Browser           │
│      ▲               │    │ iOS App           │
│ HomeKitManager       │    │ AI Assistant      │
│      ▲               │    └────────┬─────────┘
│ WKWebView (web app)  │             │
│      ▲               │     HTTP/WS │
│ LocalHTTPServer ─────┼─────────────┘
│  (port 5656/5657)    │
└──────────────────────┘
```

1. Mac app starts a local HTTP server (NWListener, port 5656) and WebSocket server (NWProtocolWebSocket, port 5657)
2. WKWebView loads the bundled web app from `http://localhost:5656`
3. Web app talks to HomeKit via the native JavaScript bridge (`window.homekit`)
4. External clients connect to the Mac's IP/hostname for device control
5. All data persists locally in IndexedDB

## Key Technologies

| Component | Stack |
|-----------|-------|
| **Mac app** | Swift/SwiftUI, Mac Catalyst, HomeKit Framework, NWListener |
| **Web app** | React 18, Vite, Tailwind CSS, Radix UI (shadcn/ui) |
| **Persistence** | IndexedDB (in WKWebView) |
| **Tauri app** | Rust, wraps web app |

## API Endpoints (Local Server)

| Endpoint | Purpose |
|----------|---------|
| `GET /rest/homes` | List HomeKit homes |
| `GET /rest/accessories` | List accessories (filter: `?home=X&room=X`) |
| `GET /rest/accessories/:id` | Get single accessory |
| `POST /rest/state` | Control devices |
| `GET /rest/scenes` | List scenes (`?home=X`) |
| `POST /rest/scenes/:id/execute` | Execute a scene |
| `GET /rest/rooms` | List rooms (`?home=X`) |
| `POST /mcp` | MCP endpoint for AI assistants |
| `GET /health` | Health check |
| `GET /config.json` | Server config (mode, version, ports) |
| `WebSocket :5657` | Real-time updates |

## Relay Protocol (WebSocket)

Messages use this JSON format:

```json
{"id": "uuid", "type": "request|response", "action": "action.name", "payload": {}}
```

### Actions

| Action | Description |
|--------|-------------|
| `homes.list` | List all HomeKit homes |
| `rooms.list` | List rooms in a home |
| `zones.list` | List zones in a home |
| `accessories.list` | List accessories |
| `accessory.get` | Get single accessory |
| `accessory.refresh` | Force-refresh accessory state |
| `characteristic.get` | Read a characteristic value |
| `characteristic.set` | Control device |
| `scenes.list` | List scenes |
| `scene.execute` | Execute a scene |
| `serviceGroups.list` | List service groups |
| `serviceGroup.set` | Update a service group |
| `automations.list` | List automations |
| `automation.get` | Get single automation |
| `automation.create` | Create automation |
| `automation.update` | Update automation |
| `automation.delete` | Delete automation |
| `automation.enable` | Enable automation |
| `automation.disable` | Disable automation |
| `state.set` | Bulk state updates |
| `observe.start` | Start observing characteristic changes |
| `observe.stop` | Stop observing |
| `observe.reset` | Reset all observers |
| `ping` | Heartbeat / keepalive |

## Key Files

| File | Purpose |
|------|---------|
| `app-ios-macos/Sources/Server/LocalHTTPServer.swift` | NWListener HTTP + WS server |
| `app-ios-macos/Sources/Server/LocalNetworkBridge.swift` | Swift ↔ JS bridge for external clients |
| `app-ios-macos/Sources/App/HomecastApp.swift` | SwiftUI app, WKWebView, mode selector |
| `app-ios-macos/Sources/HomeKit/HomeKitBridge.swift` | JS-to-native HomeKit bridge |
| `app-ios-macos/Sources/HomeKit/HomeKitManager.swift` | Central HomeKit operations |
| `app-web/src/server/local-server.ts` | WebSocket request handler |
| `app-web/src/server/local-graphql.ts` | GraphQL resolver (IndexedDB-backed) |
| `app-web/src/server/local-db.ts` | IndexedDB persistence layer |
| `app-web/src/server/local-auth.ts` | Local authentication (PBKDF2 + JWT) |
| `app-web/src/server/local-rest.ts` | REST API endpoints |
| `app-web/src/server/local-mcp.ts` | MCP endpoint |
| `app-web/src/server/local-broadcast.ts` | Event broadcasting to clients |
| `app-web/src/relay/local-handler.ts` | HomeKit action execution |
| `app-web/src/lib/config.ts` | Mode detection (Community vs Cloud) |

## Adding New Swift Files

New `.swift` files must be added to `Homecast.xcodeproj/project.pbxproj` in 4 places: PBXBuildFile, PBXFileReference, PBXGroup children, PBXSourcesBuildPhase. Use the next available ID in the `C1` prefix range for Server files.

## Common Tasks

```bash
# Build web app
cd app-web && npm run build

# Bundle web app into Mac app
cd app-ios-macos && ./scripts/bundle-web-app.sh

# Build Mac app (command line)
cd app-ios-macos && xcodebuild -project Homecast.xcodeproj \
  -scheme Homecast -destination 'platform=macOS,variant=Mac Catalyst' \
  -configuration Debug build

# Run docs dev server (source lives in homecast-cloud/docs/)
cd ../homecast-cloud/docs && npm run docs:dev
```

## Community Mode Architecture

The web app detects Community mode via:
1. `window.__HOMECAST_COMMUNITY__` (injected by local server into HTML)
2. Hostname fallback (localhost, .local, private IPs)

When in Community mode:
- `CommunityAuthProvider` handles local auth (username + password, JWT in localStorage)
- `communityRequest()` in `connection.ts` caches HomeKit data (5-min TTL, stale-while-revalidate)
- `local-server.ts` handles WebSocket requests from external clients
- `local-broadcast.ts` pushes HomeKit events to all connected clients
- GraphQL operations route to `local-graphql.ts` (IndexedDB-backed)
- `communityLocalLink` in Apollo Client bypasses HTTP on the relay Mac

## Cloud Features (`@homecast/cloud`)

Cloud-specific UI components (admin panel, billing, cloud relay management) live in the `homecast-cloud` repo's `app-web/` package. The Vite alias `@homecast/cloud` resolves to `src/cloud/index.ts` if present (copied in by CI during cloud builds), otherwise falls back to `src/cloud-stub.ts` which exports `CLOUD_AVAILABLE = false`.

**Community builds use the stub by default** — no `src/cloud/` directory exists in this repo.

## License

MIT — see [LICENSE](LICENSE).
