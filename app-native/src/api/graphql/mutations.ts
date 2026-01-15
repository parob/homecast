import { gql } from '@apollo/client';

// Auth mutations - inline fields instead of using fragment to avoid type name issues
export const LOGIN_MUTATION = gql`
  mutation Login($email: String!, $password: String!) {
    login(email: $email, password: $password) {
      success
      token
      error
      userId
      email
    }
  }
`;

export const SIGNUP_MUTATION = gql`
  mutation Signup($email: String!, $password: String!, $name: String) {
    signup(email: $email, password: $password, name: $name) {
      success
      token
      error
      userId
      email
    }
  }
`;

export const UPDATE_SETTINGS_MUTATION = gql`
  mutation UpdateSettings($data: String!) {
    updateSettings(data: $data) {
      success
      settings {
        data
      }
    }
  }
`;

export const REMOVE_DEVICE_MUTATION = gql`
  mutation RemoveDevice($deviceId: String!) {
    removeDevice(deviceId: $deviceId)
  }
`;

// HomeKit mutations
export const SET_CHARACTERISTIC_MUTATION = gql`
  mutation SetCharacteristic($accessoryId: String!, $characteristicType: String!, $value: String!) {
    setCharacteristic(
      accessoryId: $accessoryId
      characteristicType: $characteristicType
      value: $value
    ) {
      success
      accessoryId
      characteristicType
      value
    }
  }
`;

export const EXECUTE_SCENE_MUTATION = gql`
  mutation ExecuteScene($sceneId: String!) {
    executeScene(sceneId: $sceneId) {
      success
      sceneId
    }
  }
`;

export const SET_SERVICE_GROUP_MUTATION = gql`
  mutation SetServiceGroup(
    $homeId: String!
    $groupId: String!
    $characteristicType: String!
    $value: String!
  ) {
    setServiceGroup(
      homeId: $homeId
      groupId: $groupId
      characteristicType: $characteristicType
      value: $value
    ) {
      success
      groupId
      characteristicType
      affectedCount
      value
    }
  }
`;

// Collection mutations
export const CREATE_COLLECTION_MUTATION = gql`
  mutation CreateCollection($name: String!) {
    createCollection(name: $name) {
      id
      name
      payload
      createdAt
    }
  }
`;

export const UPDATE_COLLECTION_MUTATION = gql`
  mutation UpdateCollection(
    $collectionId: String!
    $name: String
    $payload: String
    $settingsJson: String
  ) {
    updateCollection(
      collectionId: $collectionId
      name: $name
      payload: $payload
      settingsJson: $settingsJson
    ) {
      id
      name
      payload
      settingsJson
      updatedAt
    }
  }
`;

export const DELETE_COLLECTION_MUTATION = gql`
  mutation DeleteCollection($collectionId: String!) {
    deleteCollection(collectionId: $collectionId)
  }
`;

export const CREATE_COLLECTION_ACCESS_MUTATION = gql`
  mutation CreateCollectionAccess(
    $collectionId: String!
    $role: String!
    $passcode: String
    $accessSchedule: String
  ) {
    createCollectionAccess(
      collectionId: $collectionId
      role: $role
      passcode: $passcode
      accessSchedule: $accessSchedule
    ) {
      id
      collectionId
      role
      accessSchedule
      createdAt
    }
  }
`;

export const DELETE_COLLECTION_ACCESS_MUTATION = gql`
  mutation DeleteCollectionAccess($accessId: String!) {
    deleteCollectionAccess(accessId: $accessId)
  }
`;

// Public collection mutation
export const PUBLIC_SET_CHARACTERISTIC_MUTATION = gql`
  mutation PublicSetCharacteristic(
    $collectionId: String!
    $accessoryId: String!
    $characteristicType: String!
    $value: String!
    $passcode: String
  ) {
    publicSetCharacteristic(
      collectionId: $collectionId
      accessoryId: $accessoryId
      characteristicType: $characteristicType
      value: $value
      passcode: $passcode
    ) {
      success
      accessoryId
      characteristicType
      value
    }
  }
`;
