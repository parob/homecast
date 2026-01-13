# Collections Feature - Implementation Plan

## Overview

Allow users to create collections of accessories that can be shared via public links with optional passcode protection.

---

## Data Models

### Collection
The collection itself - a named grouping of accessories.

```python
class Collection(BaseModel, table=True):
    __tablename__ = "collections"

    # BaseModel provides: id, created_at
    name: str
    payload: str  # JSON array: [{"type": "home|room|accessory", "item_id": "uuid"}]
```

**URL:** `/portal/collections/{collection_id}`

**payload examples:**
```json
[
  {"type": "home", "item_id": "abc-123-..."},
  {"type": "room", "item_id": "def-456-..."},
  {"type": "accessory", "item_id": "ghi-789-..."}
]
```

### CollectionAccess
Handles both user access (ownership) AND public share configurations.

```python
class CollectionAccess(BaseModel, table=True):
    __tablename__ = "collection_access"

    # BaseModel provides: id, created_at
    collection_id: UUID  # FK to collections

    # User access (when user_id is set) or public share (when null)
    user_id: Optional[UUID]  # FK to users, null for public shares
    role: str  # "owner" | "control" | "view"

    # Public share config (only used when user_id is null)
    passcode_hash: Optional[str]
    access_schedule: Optional[str]  # JSON: schedule config (see below)
```

**access_schedule format (JSON):**
```json
{
  "expires_at": "2024-12-31T23:59:59Z",
  "time_windows": [
    {"days": ["mon", "tue", "wed", "thu", "fri"], "start": "09:00", "end": "17:00"},
    {"days": ["sat"], "start": "10:00", "end": "14:00"}
  ],
  "timezone": "America/New_York"
}
```

All fields optional:
- `expires_at` - ISO datetime, access denied after this time
- `time_windows` - array of allowed time periods (if empty/missing, always allowed)
- `timezone` - for interpreting time_windows (defaults to UTC)

**Two modes:**
1. **User access:** `user_id` set, `role` = owner/control/view
2. **Public share:** `user_id` null, `role` = control/view, optional `passcode_hash` and `access_schedule`

**Role values:**
- `owner` - full access (edit collection, manage shares, control devices) - user access only
- `control` - can view and control accessories
- `view` - read-only access

**Multiple shares:** One collection can have multiple public share configs with different passcodes/roles.

---

## User Flows

### Collection Owner
1. Create collection → enter name
2. Collection appears in dashboard
3. Open collection → add items (homes, rooms, accessories)
4. Create share config(s):
   - Set access level (view/control)
   - Optional passcode
   - Optional expiration
5. Share URL: `/portal/collections/{collection_id}`

### Public Visitor
1. Visit `/portal/collections/{collection_id}`
2. System checks for valid share configs:
   - If config exists without passcode → grant access
   - If all configs require passcode → prompt for passcode
   - If passcode matches a config → grant that config's access level
3. View/control accessories based on access level

### Logged-in User Visiting Shared Collection
1. Visit `/portal/collections/{collection_id}`
2. Same flow as public visitor
3. If public (no passcode required) → option to "Save to my collections"
4. Saving creates CollectionAccess with role=viewer

---

## API Design

### GraphQL Types

```graphql
type CollectionItem {
  type: String!        # "home" | "room" | "accessory"
  itemId: String!
}

type ShareConfig {
  id: String!
  role: String!         # "view" | "control"
  hasPasscode: Boolean!
  schedule: AccessSchedule
  createdAt: String!
}

type AccessSchedule {
  expiresAt: String
  timeWindows: [TimeWindow!]
  timezone: String
}

type TimeWindow {
  days: [String!]!      # "mon", "tue", etc.
  start: String!        # "HH:MM"
  end: String!          # "HH:MM"
}

type Collection {
  id: String!
  name: String!
  items: [CollectionItem!]!
  role: String          # User's role if they have access
  shareConfigs: [ShareConfig!]  # Only for owners
}

type SharedCollectionInfo {
  id: String!
  name: String!
  requiresPasscode: Boolean!
  role: String          # Only set after passcode verified ("view" | "control")
}
```

### Authenticated Endpoints

```graphql
# Collection CRUD
mutation createCollection(name: String!): CollectionResult
mutation updateCollection(collectionId: String!, name: String, items: String): CollectionResult
mutation removeCollection(collectionId: String!): Boolean

query collections: [Collection!]!

# Share management
mutation createShareConfig(
  collectionId: String!
  role: String!        # "view" | "control"
  passcode: String
  schedule: AccessScheduleInput
): ShareConfigResult

input AccessScheduleInput {
  expiresAt: String
  timeWindows: [TimeWindowInput!]
  timezone: String
}

input TimeWindowInput {
  days: [String!]!
  start: String!
  end: String!
}

mutation deleteShareConfig(shareConfigId: String!): Boolean

# Save someone else's collection
mutation saveCollection(collectionId: String!): CollectionResult
```

### Public Endpoints

```graphql
# Get collection info (no passcode needed)
query sharedCollectionInfo(collectionId: String!): SharedCollectionInfo

# Get collection state (passcode needed if required)
query sharedCollectionState(collectionId: String!, passcode: String): String

# Control accessories (passcode needed if required, only if access_level=control)
mutation setSharedCollectionState(
  collectionId: String!
  passcode: String
  state: String!
): SetStateResult
```

---

## Frontend Components

### Routes
```
/portal                          - Dashboard (includes Collections section)
/portal/collections/:collectionId - Collection view (public or authenticated)
```

### Components

**Dashboard Integration:**
- `CollectionList` - List of user's collections (owned + saved)
- `CollectionCard` - Single collection with actions
- `CreateCollectionDialog` - Create new collection (name only)
- `CollectionView` - Inside a collection, manage items and shares
- `AddItemDialog` - Browse and add homes/rooms/accessories
- `ShareConfigList` - List of share configs for a collection
- `CreateShareDialog` - Create new share config

**Public View:**
- `SharedCollectionView` - Public collection page
- `PasscodeForm` - Enter passcode if required

### State

```typescript
interface CollectionItem {
  type: 'home' | 'room' | 'accessory';
  itemId: string;
}

interface TimeWindow {
  days: string[];       // ['mon', 'tue', ...]
  start: string;        // 'HH:MM'
  end: string;          // 'HH:MM'
}

interface AccessSchedule {
  expiresAt?: string;
  timeWindows?: TimeWindow[];
  timezone?: string;
}

interface ShareConfig {
  id: string;
  role: 'view' | 'control';
  hasPasscode: boolean;
  schedule?: AccessSchedule;
  createdAt: string;
}

interface Collection {
  id: string;
  name: string;
  items: CollectionItem[];
  role?: 'owner' | 'control' | 'view';
  shareConfigs?: ShareConfig[];
}
```

---

## Repository Methods

```python
class CollectionRepository:
    # Collection CRUD
    create_collection(session, user_id, name) -> Collection
    get_user_collections(session, user_id) -> List[(Collection, role)]
    get_collection(session, collection_id) -> Collection
    update_collection(session, collection_id, name?, payload?) -> Collection
    delete_collection(session, collection_id) -> bool

    # User access
    get_user_role(session, user_id, collection_id) -> str?
    grant_access(session, user_id, collection_id, role) -> CollectionAccess
    revoke_access(session, user_id, collection_id) -> bool

    # Public shares
    create_share(session, collection_id, role, passcode?, schedule?) -> CollectionAccess
    get_share_configs(session, collection_id) -> List[CollectionAccess]
    delete_share(session, share_id) -> bool

    # Public access
    get_valid_share(session, collection_id, passcode?) -> CollectionAccess?
    is_schedule_active(schedule_json) -> bool  # Check if current time is within schedule

    # Save collection
    save_collection(session, user_id, collection_id) -> CollectionAccess

    # Items
    get_items(collection) -> List[dict]
    set_items(session, collection_id, items) -> Collection
    add_item(session, collection_id, item) -> Collection
    remove_item(session, collection_id, item_index) -> Collection
```

---

## Security Considerations

1. **Passcode hashing:** PBKDF2-SHA256 with random salt, 100k iterations
2. **Access validation:** Always check share config validity (expiration, passcode)
3. **Owner verification:** Only owners can manage share configs
4. **Rate limiting:** Consider rate limiting passcode attempts

---

## Implementation Order

### Phase 1: Backend Models & Repository
- [x] Collection model
- [x] CollectionAccess model (unified for user access + public shares)
- [x] CollectionRepository with all methods

### Phase 2: Backend API
- [ ] Update GraphQL types (Collection, ShareConfig, etc.)
- [ ] Update authenticated endpoints
- [ ] Update public endpoints
- [ ] Remove old share-related code from Collection model references

### Phase 3: Frontend Types & GraphQL
- [ ] Update TypeScript types
- [ ] Update queries and mutations

### Phase 4: Frontend Components
- [ ] Update CollectionCard to show share configs
- [ ] Update ShareCollectionDialog → CreateShareDialog
- [ ] Update CollectionList
- [ ] Update SharedCollectionView for new flow

### Phase 5: Dashboard Integration
- [ ] Add Collections section to Dashboard sidebar
- [ ] Collection view/edit UI

---

## Files to Modify

### Backend
| File | Changes |
|------|---------|
| `models/db/models.py` | Done - Collection, CollectionAccess |
| `models/db/repositories/collection_repository.py` | Done - updated methods |
| `api/api.py` | Update types and endpoints |

### Frontend
| File | Changes |
|------|---------|
| `lib/graphql/types.ts` | Update Collection, add ShareConfig |
| `lib/graphql/queries.ts` | Update collection queries |
| `lib/graphql/mutations.ts` | Update collection mutations |
| `components/collections/*.tsx` | Update all components |
| `pages/SharedCollectionView.tsx` | Update for new flow |
| `pages/Dashboard.tsx` | Add Collections section |
