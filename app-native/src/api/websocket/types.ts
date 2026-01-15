// WebSocket message types matching server/homecast/websocket/web_clients.py

export type WebSocketMessageType =
  | 'ping'
  | 'pong'
  | 'characteristic_update'
  | 'reachability_update';

export interface BaseMessage {
  type: WebSocketMessageType;
}

export interface PingMessage extends BaseMessage {
  type: 'ping';
}

export interface PongMessage extends BaseMessage {
  type: 'pong';
}

export interface CharacteristicUpdateMessage extends BaseMessage {
  type: 'characteristic_update';
  accessoryId: string;
  characteristicType: string;
  value: unknown;
}

export interface ReachabilityUpdateMessage extends BaseMessage {
  type: 'reachability_update';
  accessoryId: string;
  isReachable: boolean;
}

export type WebSocketMessage =
  | PingMessage
  | PongMessage
  | CharacteristicUpdateMessage
  | ReachabilityUpdateMessage;

export type MessageHandler = (message: WebSocketMessage) => void;
