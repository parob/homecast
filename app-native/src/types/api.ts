// API response types matching GraphQL schema

export interface AuthResult {
  success: boolean;
  token?: string;
  error?: string;
  userId?: string;
  email?: string;
}

export interface UserInfo {
  id: string;
  email: string;
  name?: string;
  createdAt: string;
  lastLoginAt?: string;
}

export interface DeviceInfo {
  id: string;
  deviceId?: string;
  name?: string;
  sessionType: string;
  lastSeenAt?: string;
}

export interface UserSettings {
  data: string; // JSON blob
}

export interface SetCharacteristicResult {
  success: boolean;
  accessoryId: string;
  characteristicType: string;
  value?: string;
}

export interface ExecuteSceneResult {
  success: boolean;
  sceneId: string;
}

export interface SetServiceGroupResult {
  success: boolean;
  groupId: string;
  characteristicType: string;
  affectedCount: number;
  value?: string;
}

// Collection types
export interface Collection {
  id: string;
  name: string;
  payload: string; // JSON array of items
  settingsJson?: string;
  createdAt: string;
}

export interface CollectionAccess {
  id: string;
  collectionId: string;
  userId?: string;
  role: 'owner' | 'control' | 'view';
  passcodeHash?: string;
  accessSchedule?: string;
  createdAt: string;
}

export interface CollectionItem {
  type: 'accessory' | 'scene';
  itemId: string;
}
