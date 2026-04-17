# Homecast Community Edition

> `AGENTS.md` and `CLAUDE.md` are identical. Keep them in sync.

Homecast connects Apple HomeKit smart home devices to open standards (REST, MCP, WebSocket), enabling remote control, API access, and AI assistant integration.

The Community Edition runs entirely on a Mac — no cloud server needed.

## Multi-Repo Product

Homecast is a single product split across multiple repos. When working in any one repo, **search across all of them** — features, bugs, and context frequently span repos.

| Repo | Path | Description |
|------|------|-------------|
| [parob/homecast](https://github.com/parob/homecast) | `homecast/` | Mac app (Swift) + this CLAUDE.md (PUBLIC, MIT) |
| [parob/homecast-web](https://github.com/parob/homecast-web) | `homecast/app-web/` | Web app — nested inside homecast as a subdir (PUBLIC, MIT) |
| [parob/homecast-cloud](https://github.com/parob/homecast-cloud) | `homecast-cloud/` | Cloud server (Python) + cloud UI + docs site (PRIVATE) |
| [parob/homecast-hass](https://github.com/parob/homecast-hass) | `homecast-hass/` | Home Assistant integration (PUBLIC) |

All repos live as siblings under `~/Documents/GitHub/`. The web app is a separate git repo checked out inside `homecast/app-web/`.

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
Your Mac                         LAN / Tunnel          External
┌──────────────────────┐    ┌──────────────────┐    ┌─────────────┐
│ HomeKit Framework    │    │ Browser           │    │ MQTT Broker │
│      ▲               │    │ iOS App           │    └──────▲──────┘
│ HomeKitManager       │    │ AI Assistant      │           │ MQTT
│      ▲               │    └────────┬─────────┘           │
│ WKWebView (web app)  │             │                     │
│      ▲               │     HTTP/WS │                     │
│ LocalHTTPServer ─────┼─────────────┘                     │
│ MQTTBridge ──────────┼───────────────────────────────────┘
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
| `GET /rest/state` | Get simplified device state (`?home=X&room=X&type=X&name=X`) |
| `POST /rest/state` | Control devices |
| `GET /rest/accessories` | List accessories (filter: `?home=X&room=X`) |
| `GET /rest/accessories/:id` | Get single accessory |
| `GET /rest/scenes` | List scenes (`?home=X`) |
| `POST /rest/scenes/:id/execute` | Execute a scene by ID |
| `POST /rest/scene` | Execute a scene by name (`{home, name}`) |
| `GET /rest/rooms` | List rooms (`?home=X`) |
| `POST /mcp` | MCP endpoint (tools: `get_state`, `set_state`, `run_scene`) |
| `WebSocket :5657` | Real-time updates |

`/rest/*` and `/mcp` are handled by JS (`local-rest.ts`, `local-mcp.ts`) via the Swift→JS bridge. `/health` and `/config.json` are served directly by `LocalHTTPServer.swift` (they respond before the web app is loaded) and return `{mode, version, port, wsPort, mqtt}`.

## MQTT

Homecast publishes device state to MQTT brokers and accepts commands via MQTT. Follows the Zigbee2MQTT convention: base topic is state, `/set` for commands.

### Topic Structure

```
homecast/{home}/{room}/{accessory}              # retained device state (JSON, sorted keys)
homecast/{home}/{room}/{accessory}/set          # publish here to control a device
homecast/{home}/{room}/{accessory}/availability # "online" or "offline"
homecast/{home}/{room}/{group}                  # service group state
homecast/{home}/{room}/{group}/set              # control all devices in group
homecast/{home}/{room}/{group}/members          # JSON array of member accessory slugs
homecast/{home}/status                          # home online/offline (LWT)
homeassistant/{component}/homecast_{id}/config  # HA auto-discovery
```

Slugs: `{name}-{first 4 hex of UUID}` (e.g., `county-hall-2d10`, `kitchen-dfee`).

### Community Mode

Mac app connects as MQTT client to user-configured broker(s). Per-home, stored in UserDefaults. Settings at: Settings → Homes → [Home] → MQTT (requires Developer Mode).

### Cloud Mode

Managed broker at `mqtt.homecast.cloud` (EMQX on GCE). Per-home `mqtt_enabled` toggle. Auth via API access token as MQTT password (username blank). Custom brokers stored in DB via GraphQL.

MQTT Browser at `mqtt.homecast.cloud` — real-time topic viewer with visual controls, auto-connects via cross-subdomain cookie.

### Authentication

Auth depends on which broker is being used:

- **Community mode (user-configured broker):** whatever the broker accepts. `MQTTBrokerConfig` takes arbitrary `username`/`password`; Homecast passes them through unchanged. If the broker requires no auth, leave both blank.
- **Cloud mode (`mqtt.homecast.cloud`):** Homecast API access token (`hc_...`) as the password, username blank.
- **Port:** 8883 (TLS) or 1883 in both modes.

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
| `app-ios-macos/Sources/Server/MQTTBridge.swift` | HomeKit ↔ MQTT bridge (state publish, command subscribe) |
| `app-ios-macos/Sources/Server/MQTTClient.swift` | MQTT 3.1.1 client (NWConnection-based) |
| `app-ios-macos/Sources/Server/MQTTDiscovery.swift` | Home Assistant MQTT auto-discovery config generator |
| `app-ios-macos/Sources/Server/NotificationManager.swift` | Local + remote push notifications |
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
| `app-web/src/pages/MQTTBrowser.tsx` | MQTT browser page (`/mqtt` and `mqtt.homecast.cloud`) |
| `app-web/src/components/settings/HomeDetailView.tsx` | Per-home MQTT broker toggle + custom brokers |

## Advanced Automation Engine

The web app includes an n8n-style visual automation engine with data flow between nodes.

### Architecture

```
app-web/src/automation/           # Engine core
├── engine/
│   ├── AutomationEngine.ts       # Orchestrator: lifecycle, trigger → condition → action
│   ├── ActionExecutor.ts         # Executes actions, captures per-node output, error handling
│   ├── TriggerManager.ts         # Registers triggers, service group support
│   ├── ConditionEvaluator.ts     # AND/OR/NOT condition trees
│   ├── ExecutionContext.ts       # Per-run state: nodeOutputs, variables, trace
│   └── ScriptRunner.ts           # Reusable script execution
├── expression/
│   ├── ExpressionEngine.ts       # Template resolution: {{ nodes.http1.data.body }}
│   ├── ExpressionLexer.ts        # Tokenizer
│   ├── ExpressionParser.ts       # AST parser
│   ├── ExpressionEval.ts         # AST evaluator with nodes/trigger/variables context
│   └── functions.ts              # Built-in: states(), is_state(), now(), min/max, etc.
├── state/StateStore.ts           # Reactive device state tracking
├── types/automation.ts           # All type definitions (triggers, actions, conditions)
└── types/execution.ts            # ExecutionTrace, TraceStep, StateChangeEvent

app-web/src/components/automation-editor/  # Visual editor
├── AutomationEditorDialog.tsx    # Main dialog: canvas, toolbar, undo/redo
├── constants.ts                  # Node definitions, output schemas, categories
├── nodes/BaseNode.tsx            # Universal node renderer (multi-input/output handles)
├── panels/
│   ├── NodePalette.tsx           # Drag-and-drop palette
│   ├── NodeConfigPanel.tsx       # Right tray config (per-node-type forms)
│   └── ExecutionHistoryPanel.tsx # Execution trace viewer
├── edges/ControlFlowEdge.tsx     # Smooth step edges
└── serialization/
    ├── graphToAutomation.ts      # React Flow graph → Automation JSON
    └── automationToGraph.ts      # Automation JSON → React Flow graph
```

### Data Flow Model

Every node captures output accessible to downstream nodes via expressions:
- `{{ nodes.http1.data.body.temperature }}` — access HTTP response body
- `{{ nodes.code1.data.result }}` — access code node return value
- `{{ trigger.to_value }}` — access trigger data
- Node IDs with hyphens require bracket notation: `{{ nodes['http-1'].data.status }}`

Output schemas are defined in `NODE_OUTPUT_SCHEMAS` in `constants.ts`.

### Node Types (Palette)

| Node | Category | Engine Type | Description |
|------|----------|-------------|-------------|
| Device Changed | trigger | `state` / `numeric_state` | Device or service group state change |
| Schedule | trigger | `time` / `time_pattern` / `sun` | Time-based triggers |
| Webhook | trigger | `webhook` | HTTP webhook trigger |
| Set Device | action | `set_characteristic` | Control a device |
| Run Scene | action | `execute_scene` | Execute HomeKit scene |
| Delay | action | `delay` | Wait for duration |
| Notify | action | `notify` | Push/email/local notification (with action buttons) |
| HTTP Request | action | `fire_webhook` | HTTP request (response captured as output) |
| Code | action | `code` | Sandboxed JavaScript (receives `input` object) |
| IF | logic | `if_then_else` | Conditional branch (true/false outputs) |
| Wait | logic | `wait_for_trigger` | Pause until condition or timeout |
| Merge | logic | `merge` | Combine data from multiple branches (2 input handles) |
| Sub-workflow | logic | `call_script` | Execute another automation |

### Service Group Triggers

Triggers can reference a service group instead of individual accessory:
- `serviceGroupId` on `StateTrigger`/`NumericStateTrigger` (mutually exclusive with `accessoryId`)
- `TriggerManager` uses `ServiceGroupResolver.getGroupsForAccessory()` for dynamic reverse-index lookup
- Group membership changes reflected immediately (no re-registration needed)

### Per-Node Error Handling

Actions support `onError: 'stop' | 'continue' | 'retry'`:
- `stop` (default): error propagates, automation halts
- `continue`: error logged in node output, next action proceeds
- `retry`: exponential backoff up to `maxRetries`, then continues

### Persistence (IndexedDB)

| Store | Key | Purpose |
|-------|-----|---------|
| `hc_automations` | `id` | Automation definitions (JSON) |
| `execution_traces` | `id` (index: `automationId`) | Execution history (100 per automation) |
| `automation_versions` | `id` (index: `automationId`) | Version snapshots (50 per automation, auto-created on save) |
| `credentials` | `id` | Encrypted credentials for HTTP nodes |

### Push Notifications (Cloud Only)

The Notify action node delivers notifications via 2 configurable channels + automatic relay alert:

| Channel | Mechanism | Recipient | Configurable |
|---------|-----------|-----------|-------------|
| Relay alert | `UNUserNotificationCenter` on relay Mac | Relay owner (instant, no internet) | Always on |
| Push | Web Push (FCM) to browsers + APNs to Mac/iOS apps | You + home members | Toggle in settings |
| Email | Maileroo | You + home members | Toggle in settings (off by default) |

Server deduplicates: relay Mac's APNs token is skipped (it already showed the local alert).

**Key files:**

| File | Purpose |
|------|---------|
| `app-web/public/firebase-messaging-sw.js` | FCM service worker (background push) |
| `app-web/src/hooks/usePushNotifications.ts` | Permission flow, FCM token registration |
| `app-web/src/lib/firebase.ts` | Firebase config (project `homecast-483609`) |
| `app-web/src/components/settings/NotificationsSection.tsx` | Settings UI (global prefs, devices, history) |
| `app-ios-macos/Sources/Server/NotificationManager.swift` | Local + remote notifications |

**Notification preference hierarchy** (most specific wins): automation > home > global > defaults (push=on, email=off). UI shows 2 toggles only (Push + Email). Relay alert is always on.

**Rate limits:** 30 push/hr per automation, 200 push/day per user, 5 email/hr per automation, 50 email/day per user.

**Bridge methods:** `notification.show`, `notification.requestPermission`, `notification.getAPNsToken`

### Testing

```bash
cd app-web
npm test              # Run all tests
npm run test:watch    # Watch mode
npx vitest run src/automation/  # Automation tests only
```

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

## Deployment & Environments

The web app (`app-web/`) runs in **two different ways** depending on mode:

| Mode | Where web app loads from | How to deploy |
|------|-------------------------|---------------|
| **Community** | Bundled in Mac app (`Resources/web-dist/`) | `./scripts/bundle-web-app.sh` → rebuild Mac app |
| **Cloud** | Served from Firebase Hosting (`homecast.cloud`) | Push to `app-web` repo → promote via CI |

### Cloud deployment pipeline

```
app-web push to main
  → CI triggers "Deploy Web App to Staging" on homecast-cloud (automatic)
  → staging.homecast.cloud updated

To promote to production:
  → Run "Deploy Web App to Production" workflow on homecast-cloud
  → gh workflow run "Deploy Web App to Production" --ref main -f confirm=deploy
  → homecast.cloud updated
```

**Critical:** Changes to relay code (`src/relay/local-handler.ts`, `src/server/`) affect the Mac app's WKWebView behavior. In cloud mode, the Mac app loads this code from `homecast.cloud`, NOT from the local bundle. You MUST deploy to production for cloud relay fixes to take effect. Rebuilding the Mac app alone is NOT sufficient for cloud mode.

### Verify deployment

```bash
# Check what's deployed
curl -s https://homecast.cloud/version.json
curl -s https://staging.homecast.cloud/version.json

# Check CI status
cd ~/Documents/GitHub/homecast-cloud && gh run list --workflow "Deploy Web App to Production" --limit 3
```

### Environments

| Environment | Web App | API Server | Mac App Relay |
|-------------|---------|------------|---------------|
| **Production** | `homecast.cloud` | `api.homecast.cloud` | Connects via WS to `api.homecast.cloud`, loads UI from `homecast.cloud` |
| **Staging** | `staging.homecast.cloud` | `staging.api.homecast.cloud` | Connects via WS to `staging.api.homecast.cloud`, loads UI from `staging.homecast.cloud` |
| **Community** | Bundled in Mac app | N/A (all local) | Serves from `localhost:5656`, uses bundled `web-dist/` |

The Mac app's environment is set via `AppConfig.isStaging` (UserDefaults) and `AppConfig.isCommunity`. The relay MUST be connected to the same environment that the client (HA, browser) is using.

## License

MIT — see [LICENSE](LICENSE).
