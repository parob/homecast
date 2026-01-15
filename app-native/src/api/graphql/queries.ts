import { gql } from '@apollo/client';

// Auth fragments and queries
export const AUTH_RESULT_FRAGMENT = gql`
  fragment AuthResultFields on AuthResult {
    success
    token
    error
    userId
    email
  }
`;

export const USER_INFO_FRAGMENT = gql`
  fragment UserInfoFields on UserInfo {
    id
    email
    name
    createdAt
    lastLoginAt
  }
`;

export const ME_QUERY = gql`
  query Me {
    me {
      ...UserInfoFields
    }
  }
  ${USER_INFO_FRAGMENT}
`;

export const SETTINGS_QUERY = gql`
  query Settings {
    settings {
      data
    }
  }
`;

export const DEVICES_QUERY = gql`
  query Devices {
    devices {
      id
      deviceId
      name
      sessionType
      lastSeenAt
    }
  }
`;

// HomeKit fragments
export const CHARACTERISTIC_FRAGMENT = gql`
  fragment CharacteristicFields on HomeKitCharacteristic {
    id
    characteristicType
    value
    isReadable
    isWritable
    validValues
    minValue
    maxValue
    stepValue
  }
`;

export const SERVICE_FRAGMENT = gql`
  fragment ServiceFields on HomeKitService {
    id
    name
    serviceType
    characteristics {
      ...CharacteristicFields
    }
  }
  ${CHARACTERISTIC_FRAGMENT}
`;

export const ACCESSORY_FRAGMENT = gql`
  fragment AccessoryFields on HomeKitAccessory {
    id
    name
    category
    isReachable
    homeId
    roomId
    roomName
    services {
      ...ServiceFields
    }
  }
  ${SERVICE_FRAGMENT}
`;

export const HOME_FRAGMENT = gql`
  fragment HomeFields on HomeKitHome {
    id
    name
    isPrimary
    roomCount
    accessoryCount
  }
`;

export const ROOM_FRAGMENT = gql`
  fragment RoomFields on HomeKitRoom {
    id
    name
    accessoryCount
  }
`;

export const SCENE_FRAGMENT = gql`
  fragment SceneFields on HomeKitScene {
    id
    name
    actionCount
  }
`;

// HomeKit queries
export const HOMES_QUERY = gql`
  query Homes {
    homes {
      ...HomeFields
    }
  }
  ${HOME_FRAGMENT}
`;

export const ROOMS_QUERY = gql`
  query Rooms($homeId: String!) {
    rooms(homeId: $homeId) {
      ...RoomFields
    }
  }
  ${ROOM_FRAGMENT}
`;

export const ACCESSORIES_QUERY = gql`
  query Accessories($homeId: String, $roomId: String) {
    accessories(homeId: $homeId, roomId: $roomId) {
      ...AccessoryFields
    }
  }
  ${ACCESSORY_FRAGMENT}
`;

export const ACCESSORY_QUERY = gql`
  query Accessory($accessoryId: String!) {
    accessory(accessoryId: $accessoryId) {
      ...AccessoryFields
    }
  }
  ${ACCESSORY_FRAGMENT}
`;

export const SCENES_QUERY = gql`
  query Scenes($homeId: String!) {
    scenes(homeId: $homeId) {
      ...SceneFields
    }
  }
  ${SCENE_FRAGMENT}
`;

export const ZONES_QUERY = gql`
  query Zones($homeId: String!) {
    zones(homeId: $homeId) {
      id
      name
      roomIds
    }
  }
`;

export const SERVICE_GROUPS_QUERY = gql`
  query ServiceGroups($homeId: String!) {
    serviceGroups(homeId: $homeId) {
      id
      name
      serviceIds
      accessoryIds
    }
  }
`;

// Collection queries
export const COLLECTIONS_QUERY = gql`
  query Collections {
    collections {
      id
      name
      payload
      settingsJson
      createdAt
    }
  }
`;

export const COLLECTION_QUERY = gql`
  query Collection($collectionId: String!) {
    collection(collectionId: $collectionId) {
      id
      name
      payload
      settingsJson
      createdAt
    }
  }
`;

export const COLLECTION_ACCESS_QUERY = gql`
  query CollectionAccess($collectionId: String!) {
    collectionAccess(collectionId: $collectionId) {
      id
      collectionId
      userId
      role
      accessSchedule
      createdAt
    }
  }
`;

// Public collection query
export const PUBLIC_COLLECTION_QUERY = gql`
  query PublicCollection($collectionId: String!, $passcode: String) {
    publicCollection(collectionId: $collectionId, passcode: $passcode) {
      id
      name
      payload
    }
  }
`;
