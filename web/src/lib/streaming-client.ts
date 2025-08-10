/**
 * WebSocket streaming client for ServiceRadar SRQL queries
 */

export interface StreamMessage {
  type: 'data' | 'error' | 'complete' | 'ping';
  data?: Record<string, unknown>;
  error?: string;
  timestamp: string;
}

export interface StreamingOptions {
  onData: (data: Record<string, unknown>) => void;
  onError: (error: string) => void;
  onComplete: () => void;
  onConnection?: (connected: boolean) => void;
}

export class StreamingClient {
  private websocket: WebSocket | null = null;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private isManualClose = false;
  private reconnectAttempts = 0;
  private maxReconnectAttempts = 5;
  private reconnectDelay = 1000;
  
  constructor(private options: StreamingOptions) {}

  connect(query: string): void {
    this.isManualClose = false;
    this.reconnectAttempts = 0;
    this.establishConnection(query);
  }

  private async establishConnection(query: string): Promise<void> {
    try {
      // Construct WebSocket URL
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      
      // For WebSocket connections, we must use the same origin to ensure cookies are sent
      // In production/staging: Use window.location.host (nginx proxies to backend)
      // In development: Also use window.location.host and let Next.js proxy handle it
      const apiHost = window.location.host;
      
      const encodedQuery = encodeURIComponent(query);
      
      // Build WebSocket URL 
      // WebSockets automatically send cookies with same-origin requests
      // The accessToken cookie will be sent automatically for authentication
      const wsUrl = `${protocol}//${apiHost}/api/stream?query=${encodedQuery}`;
      
      // Log connection details for debugging
      console.log('WebSocket connecting to:', wsUrl);
      console.log('Origin:', window.location.origin);
      console.log('Cookies will be sent automatically for same-origin authentication');
      
      // Create WebSocket connection
      // Note: Cookies are automatically sent for same-origin requests
      this.websocket = new WebSocket(wsUrl);
      // For cross-origin connections, authentication must be handled differently
      
      this.websocket.onopen = () => {
        console.log('WebSocket connected');
        this.reconnectAttempts = 0;
        this.options.onConnection?.(true);
      };

      this.websocket.onmessage = (event) => {
        try {
          const message: StreamMessage = JSON.parse(event.data);
          this.handleMessage(message);
        } catch (error) {
          console.error('Failed to parse WebSocket message:', error);
          this.options.onError('Failed to parse message from server');
        }
      };

      this.websocket.onclose = (event) => {
        console.log('WebSocket closed:', event.code, event.reason || 'no reason');
        this.options.onConnection?.(false);
        
        // Check for specific close codes that indicate different issues
        if (event.code === 1002 || event.code === 1003) {
          this.options.onError('Streaming not supported by this server version');
          return;
        } else if (event.code === 1006) {
          // 1006 is abnormal closure - often network issues, should retry
          console.log('WebSocket abnormal closure (1006) - will attempt reconnection');
          this.options.onError('Connection lost - reconnecting...');
          // Don't return - allow reconnection logic to proceed
        } else if (event.code >= 4000) {
          this.options.onError(`Server rejected connection: ${event.reason || 'authentication failed'}`);
          return;
        }
        
        if (!this.isManualClose && this.reconnectAttempts < this.maxReconnectAttempts) {
          this.scheduleReconnect(query);
        }
      };

      this.websocket.onerror = (error) => {
        console.error('WebSocket error:', error);
        
        // Provide more helpful error messages
        if (this.reconnectAttempts === 0) {
          this.options.onError('Streaming connection failed');
        } else {
          this.options.onError('WebSocket connection error');
        }
      };

    } catch (error) {
      console.error('Failed to establish WebSocket connection:', error);
      this.options.onError('Failed to establish connection');
    }
  }

  private handleMessage(message: StreamMessage): void {
    switch (message.type) {
      case 'data':
        if (message.data) {
          this.options.onData(message.data);
        }
        break;
      
      case 'error':
        if (message.error) {
          this.options.onError(message.error);
        }
        break;
      
      case 'complete':
        this.options.onComplete();
        break;
      
      case 'ping':
        // Handle ping messages (keep-alive)
        // No action needed, just acknowledge receipt
        break;
      
      default:
        console.warn('Unknown message type:', message.type);
    }
  }

  private scheduleReconnect(query: string): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
    }

    const delay = this.reconnectDelay * Math.pow(2, this.reconnectAttempts); // Exponential backoff
    this.reconnectAttempts++;

    console.log(`Scheduling reconnect attempt ${this.reconnectAttempts} in ${delay}ms`);
    
    this.reconnectTimer = setTimeout(() => {
      this.establishConnection(query);
    }, delay);
  }

  disconnect(): void {
    this.isManualClose = true;
    
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    if (this.websocket) {
      this.websocket.close();
      this.websocket = null;
    }
  }

  isConnected(): boolean {
    return this.websocket?.readyState === WebSocket.OPEN;
  }
}

// Factory function for creating streaming clients
export function createStreamingClient(options: StreamingOptions): StreamingClient {
  return new StreamingClient(options);
}