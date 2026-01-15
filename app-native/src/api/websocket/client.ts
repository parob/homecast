import { WS_WEB_URL } from '@/constants/api';
import { useConnectionStore } from '@/stores/connectionStore';
import type { WebSocketMessage, MessageHandler } from './types';

class HomecastWebSocket {
  private ws: WebSocket | null = null;
  private pingInterval: ReturnType<typeof setInterval> | null = null;
  private handlers: Set<MessageHandler> = new Set();
  private isConnecting = false;
  private token: string | null = null;
  private maxReconnectAttempts = 10;
  private baseReconnectDelay = 1000;

  connect(token: string): void {
    if (this.ws?.readyState === WebSocket.OPEN || this.isConnecting) {
      return;
    }

    this.token = token;
    this.isConnecting = true;

    const url = `${WS_WEB_URL}?token=${token}`;

    try {
      this.ws = new WebSocket(url);
    } catch (error) {
      console.error('[WS] Failed to create WebSocket:', error);
      this.isConnecting = false;
      this.scheduleReconnect();
      return;
    }

    this.ws.onopen = () => {
      console.log('[WS] Connected');
      this.isConnecting = false;
      useConnectionStore.getState().setWsConnected(true);
      useConnectionStore.getState().resetReconnectAttempts();
      this.startPing();
    };

    this.ws.onmessage = (event) => {
      try {
        const message = JSON.parse(event.data) as WebSocketMessage;
        this.handleMessage(message);
      } catch (error) {
        console.error('[WS] Failed to parse message:', error);
      }
    };

    this.ws.onerror = (error) => {
      console.error('[WS] Error:', error);
    };

    this.ws.onclose = (event) => {
      console.log('[WS] Disconnected:', event.code, event.reason);
      this.isConnecting = false;
      useConnectionStore.getState().setWsConnected(false);
      this.stopPing();

      // Attempt reconnect if not intentionally closed
      // 1000 = normal close, 4001 = invalid token
      if (event.code !== 1000 && event.code !== 4001) {
        this.scheduleReconnect();
      }
    };
  }

  private handleMessage(message: WebSocketMessage): void {
    switch (message.type) {
      case 'ping':
        // Server-initiated ping, respond with pong
        this.send({ type: 'pong' });
        useConnectionStore.getState().setLastPing(new Date());
        break;

      case 'pong':
        // Response to our ping
        useConnectionStore.getState().setLastPing(new Date());
        break;

      default:
        // Broadcast to all handlers
        this.handlers.forEach((handler) => {
          try {
            handler(message);
          } catch (error) {
            console.error('[WS] Handler error:', error);
          }
        });
    }
  }

  private startPing(): void {
    // Send ping every 30 seconds to keep connection alive
    this.pingInterval = setInterval(() => {
      this.send({ type: 'ping' });
    }, 30000);
  }

  private stopPing(): void {
    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }

  private scheduleReconnect(): void {
    const { reconnectAttempts, incrementReconnectAttempts } = useConnectionStore.getState();

    if (reconnectAttempts >= this.maxReconnectAttempts) {
      console.log('[WS] Max reconnect attempts reached');
      return;
    }

    // Exponential backoff with max of 30 seconds
    const delay = Math.min(
      this.baseReconnectDelay * Math.pow(2, reconnectAttempts),
      30000
    );

    console.log(`[WS] Reconnecting in ${delay}ms (attempt ${reconnectAttempts + 1})`);

    incrementReconnectAttempts();

    setTimeout(() => {
      if (this.token) {
        this.connect(this.token);
      }
    }, delay);
  }

  send(message: object): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(message));
    }
  }

  subscribe(handler: MessageHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  disconnect(): void {
    this.stopPing();
    this.ws?.close(1000, 'User logout');
    this.ws = null;
    this.token = null;
    // Prevent reconnect after intentional disconnect
    useConnectionStore.getState().resetReconnectAttempts();
  }

  get isConnected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }
}

// Singleton instance
export const webSocketClient = new HomecastWebSocket();
