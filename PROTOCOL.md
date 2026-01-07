# HomeKit MCP WebSocket Protocol

This document defines the WebSocket protocol used for communication between the HomeKit MCP Mac app and the Cloud Run backend.

## Connection

- **URL**: `wss://api.homekitmcp.com/ws`
- **Authentication**: Bearer token in initial handshake
- **Heartbeat**: Ping/pong every 30 seconds

## Message Format

All messages are JSON with this structure:

```json
{
  "id": "uuid-v4",
  "type": "request|response|event",
  "action": "action.name",
  "payload": { ... },
  "error": { "code": "ERROR_CODE", "message": "Human readable message" }
}
```

- `id`: Unique message ID (used to correlate requests/responses)
- `type`: Message type
- `action`: The operation being performed
- `payload`: Action-specific data
- `error`: Present only on error responses

---

## Request/Response Actions

### homes.list

List all homes.

**Request:**
```json
{
  "id": "abc123",
  "type": "request",
  "action": "homes.list",
  "payload": {}
}
```

**Response:**
```json
{
  "id": "abc123",
  "type": "response",
  "action": "homes.list",
  "payload": {
    "homes": [
      {
        "id": "uuid",
        "name": "My Home",
        "isPrimary": true,
        "roomCount": 5,
        "accessoryCount": 12,
        "sceneCount": 3
      }
    ]
  }
}
```

---

### rooms.list

List rooms in a home.

**Request:**
```json
{
  "id": "abc123",
  "type": "request",
  "action": "rooms.list",
  "payload": {
    "homeId": "uuid"
  }
}
```

**Response:**
```json
{
  "id": "abc123",
  "type": "response",
  "action": "rooms.list",
  "payload": {
    "homeId": "uuid",
    "rooms": [
      {
        "id": "uuid",
        "name": "Living Room",
        "accessoryCount": 4
      }
    ]
  }
}
```

---

### accessories.list

List accessories, optionally filtered by home or room.

**Request:**
```json
{
  "id": "abc123",
  "type": "request",
  "action": "accessories.list",
  "payload": {
    "homeId": "uuid",
    "roomId": "uuid"
  }
}
```

**Response:**
```json
{
  "id": "abc123",
  "type": "response",
  "action": "accessories.list",
  "payload": {
    "accessories": [
      {
        "id": "uuid",
        "name": "Living Room Light",
        "homeId": "uuid",
        "roomId": "uuid",
        "roomName": "Living Room",
        "category": "Lightbulb",
        "isReachable": true,
        "services": [
          {
            "id": "uuid",
            "name": "Light",
            "type": "lightbulb",
            "characteristics": [
              {
                "id": "uuid",
                "type": "power-state",
                "value": true,
                "isReadable": true,
                "isWritable": true
              },
              {
                "id": "uuid",
                "type": "brightness",
                "value": 75,
                "isReadable": true,
                "isWritable": true
              }
            ]
          }
        ]
      }
    ]
  }
}
```

---

### accessory.get

Get a single accessory with full details.

**Request:**
```json
{
  "id": "abc123",
  "type": "request",
  "action": "accessory.get",
  "payload": {
    "accessoryId": "uuid"
  }
}
```

**Response:**
```json
{
  "id": "abc123",
  "type": "response",
  "action": "accessory.get",
  "payload": {
    "accessory": { ... }
  }
}
```

---

### characteristic.get

Read the current value of a characteristic.

**Request:**
```json
{
  "id": "abc123",
  "type": "request",
  "action": "characteristic.get",
  "payload": {
    "accessoryId": "uuid",
    "characteristicType": "power-state"
  }
}
```

**Response:**
```json
{
  "id": "abc123",
  "type": "response",
  "action": "characteristic.get",
  "payload": {
    "accessoryId": "uuid",
    "characteristicType": "power-state",
    "value": true
  }
}
```

---

### characteristic.set

Set a characteristic value (control a device).

**Request:**
```json
{
  "id": "abc123",
  "type": "request",
  "action": "characteristic.set",
  "payload": {
    "accessoryId": "uuid",
    "characteristicType": "power-state",
    "value": true
  }
}
```

**Response:**
```json
{
  "id": "abc123",
  "type": "response",
  "action": "characteristic.set",
  "payload": {
    "success": true,
    "accessoryId": "uuid",
    "characteristicType": "power-state",
    "value": true
  }
}
```

---

### scenes.list

List scenes in a home.

**Request:**
```json
{
  "id": "abc123",
  "type": "request",
  "action": "scenes.list",
  "payload": {
    "homeId": "uuid"
  }
}
```

**Response:**
```json
{
  "id": "abc123",
  "type": "response",
  "action": "scenes.list",
  "payload": {
    "homeId": "uuid",
    "scenes": [
      {
        "id": "uuid",
        "name": "Good Morning",
        "actionCount": 5
      }
    ]
  }
}
```

---

### scene.execute

Execute a scene.

**Request:**
```json
{
  "id": "abc123",
  "type": "request",
  "action": "scene.execute",
  "payload": {
    "sceneId": "uuid"
  }
}
```

**Response:**
```json
{
  "id": "abc123",
  "type": "response",
  "action": "scene.execute",
  "payload": {
    "success": true,
    "sceneId": "uuid"
  }
}
```

---

## Events (App → Server)

Events are pushed from the app to the server when state changes occur.

### accessory.stateChanged

Sent when an accessory's characteristic value changes.

```json
{
  "id": "uuid",
  "type": "event",
  "action": "accessory.stateChanged",
  "payload": {
    "accessoryId": "uuid",
    "accessoryName": "Living Room Light",
    "changes": [
      {
        "characteristicType": "power-state",
        "oldValue": false,
        "newValue": true
      }
    ],
    "timestamp": "2025-01-07T12:00:00Z"
  }
}
```

### accessory.reachabilityChanged

Sent when an accessory becomes reachable or unreachable.

```json
{
  "id": "uuid",
  "type": "event",
  "action": "accessory.reachabilityChanged",
  "payload": {
    "accessoryId": "uuid",
    "accessoryName": "Kitchen Light",
    "isReachable": false,
    "timestamp": "2025-01-07T12:00:00Z"
  }
}
```

### home.configurationChanged

Sent when home configuration changes (accessory added/removed, room changed, etc.).

```json
{
  "id": "uuid",
  "type": "event",
  "action": "home.configurationChanged",
  "payload": {
    "homeId": "uuid",
    "homeName": "My Home",
    "changeType": "accessoryAdded|accessoryRemoved|roomAdded|roomRemoved|updated",
    "timestamp": "2025-01-07T12:00:00Z"
  }
}
```

---

## Error Codes

| Code | Description |
|------|-------------|
| `INVALID_REQUEST` | Malformed request |
| `UNKNOWN_ACTION` | Action not recognized |
| `HOME_NOT_FOUND` | Home ID not found |
| `ROOM_NOT_FOUND` | Room ID not found |
| `ACCESSORY_NOT_FOUND` | Accessory ID not found |
| `SCENE_NOT_FOUND` | Scene ID not found |
| `CHARACTERISTIC_NOT_FOUND` | Characteristic type not found on accessory |
| `CHARACTERISTIC_NOT_WRITABLE` | Characteristic cannot be written |
| `ACCESSORY_UNREACHABLE` | Accessory is not reachable |
| `INVALID_VALUE` | Value is not valid for this characteristic |
| `HOMEKIT_ERROR` | Generic HomeKit error |
| `INTERNAL_ERROR` | Internal server error |

**Error Response Example:**
```json
{
  "id": "abc123",
  "type": "response",
  "action": "characteristic.set",
  "error": {
    "code": "ACCESSORY_UNREACHABLE",
    "message": "The accessory 'Kitchen Light' is not reachable"
  }
}
```

---

## Characteristic Types

Common characteristic types used in the protocol:

| Type | Description | Value Type |
|------|-------------|------------|
| `power-state` | On/Off | boolean |
| `brightness` | Brightness level | integer (0-100) |
| `hue` | Color hue | float (0-360) |
| `saturation` | Color saturation | float (0-100) |
| `color-temperature` | Color temperature | integer (50-400 mireds) |
| `current-temperature` | Current temperature reading | float (°C) |
| `target-temperature` | Target temperature | float (°C) |
| `current-heating-cooling` | Current HVAC mode | integer (0=off, 1=heat, 2=cool) |
| `target-heating-cooling` | Target HVAC mode | integer (0=off, 1=heat, 2=cool, 3=auto) |
| `lock-current-state` | Current lock state | integer (0=unsecured, 1=secured, 2=jammed, 3=unknown) |
| `lock-target-state` | Target lock state | integer (0=unsecured, 1=secured) |
| `motion-detected` | Motion detected | boolean |
| `contact-state` | Contact sensor state | integer (0=detected, 1=not detected) |
| `current-position` | Current position (blinds, etc.) | integer (0-100) |
| `target-position` | Target position | integer (0-100) |
| `active` | Active state | boolean |

---

## Connection Lifecycle

1. **Connect**: App connects to WebSocket with auth token
2. **Authenticate**: Server validates token and sends `connected` event
3. **Sync**: App sends initial state with `home.configurationChanged` event
4. **Operate**: Bidirectional request/response and events
5. **Heartbeat**: Ping/pong every 30 seconds
6. **Reconnect**: On disconnect, app reconnects with exponential backoff

```
App                                     Server
 |                                        |
 |-------- WebSocket Connect ------------>|
 |<------- connected event ---------------|
 |-------- home.configurationChanged ---->|
 |                                        |
 |<------- homes.list request ------------|
 |-------- homes.list response ---------->|
 |                                        |
 |<------- characteristic.set request ----|
 |-------- characteristic.set response -->|
 |                                        |
 |-------- accessory.stateChanged ------->|
 |                                        |
