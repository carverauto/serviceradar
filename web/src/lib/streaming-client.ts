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
  private completionReceived = false; // Track if server sent completion message
  
  constructor(private options: StreamingOptions) {}

  connect(query: string): void {
    // Prevent multiple simultaneous connection attempts
    if (this.websocket && this.websocket.readyState === WebSocket.CONNECTING) {
      console.log('WebSocket already connecting, ignoring duplicate connect request');
      return;
    }

    this.isManualClose = false;
    this.reconnectAttempts = 0;
    this.completionReceived = false; // Reset completion flag for new connection
    this.establishConnection(query);
  }

  private async establishConnection(query: string): Promise<void> {
    try {
      // Clean up any existing connection first
      if (this.websocket) {
        console.log('Cleaning up existing WebSocket connection');
        this.websocket.close();
        this.websocket = null;
      }

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
      console.log('🔌 [StreamingClient] Establishing new WebSocket connection to:', wsUrl);
      console.log('📍 [StreamingClient] Origin:', window.location.origin);
      console.log('🍪 [StreamingClient] Cookies will be sent automatically for same-origin authentication');
      
      // Create WebSocket connection
      // Note: Cookies are automatically sent for same-origin requests
      this.websocket = new WebSocket(wsUrl);
      
      // Add immediate state check
      console.log('🔄 [StreamingClient] WebSocket created, initial readyState:', this.websocket.readyState);
      // For cross-origin connections, authentication must be handled differently
      
      this.websocket.onopen = () => {
        console.log('✅ [StreamingClient] WebSocket connected successfully');
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
        // Provide context-aware logging for WebSocket closures
        if (event.code === 1006 && this.completionReceived) {
          console.log('✅ [StreamingClient] WebSocket closed normally after server completion (1006 is expected for Proton batch completion)');
        } else if (event.code === 1000) {
          console.log('✅ [StreamingClient] WebSocket closed normally (1000)');
        } else if (event.code === 1006) {
          console.log('⚠️ [StreamingClient] WebSocket closed unexpectedly (1006) - this may indicate a network issue or server restart');
        } else {
          console.log(`🔴 [StreamingClient] WebSocket closed with code ${event.code}: ${event.reason || 'no reason provided'}`);
        }
        
        this.options.onConnection?.(false);
        
        // Check for specific close codes that indicate different issues
        if (event.code === 1002 || event.code === 1003) {
          this.options.onError('Streaming not supported by this server version');
          return;
        } else if (event.code === 1006) {
          // Handle 1006 based on whether we received completion
          if (this.completionReceived) {
            console.log('📝 [StreamingClient] 1006 closure after completion is normal - streaming finished successfully');
            return; // Don't attempt reconnection, this was a successful completion
          } else {
            console.log('🔄 [StreamingClient] 1006 closure without completion - may need reconnection');
            // Continue to reconnection logic below
          }
        } else if (event.code >= 4000) {
          this.options.onError(`Server rejected connection: ${event.reason || 'authentication failed'}`);
          return;
        }
        
        // Only attempt reconnection if this wasn't a successful completion
        if (!this.isManualClose && !this.completionReceived && this.reconnectAttempts < this.maxReconnectAttempts) {
          console.log('🔄 [StreamingClient] Scheduling reconnection attempt...');
          this.scheduleReconnect(query);
        } else if (this.completionReceived) {
          console.log('✅ [StreamingClient] Streaming completed successfully, no reconnection needed');
        }
      };

      this.websocket.onerror = (error) => {
        console.error('❌ [StreamingClient] WebSocket error:', error);
        console.error('🔍 [StreamingClient] WebSocket error details:', {
          url: wsUrl,
          readyState: this.websocket?.readyState,
          readyStateText: this.getReadyStateText(this.websocket?.readyState),
          cookies: document.cookie.substring(0, 100) + '...',
          origin: window.location.origin,
          timestamp: new Date().toISOString()
        });
        
        // Check if this is the "closed before established" error
        if (this.websocket?.readyState === WebSocket.CLOSED) {
          console.error('🚨 [StreamingClient] WebSocket closed before connection established!');
          this.options.onError('Connection closed before establishment - this may be due to multiple rapid connection attempts');
        } else {
          // Provide more helpful error messages
          if (this.reconnectAttempts === 0) {
            this.options.onError('Streaming connection failed - check server logs');
          } else {
            this.options.onError('WebSocket connection error');
          }
        }
      };

    } catch (error) {
      console.error('❌ [StreamingClient] Failed to establish WebSocket connection:', error);
      this.options.onError('Failed to establish connection');
    }
  }

  private getReadyStateText(readyState?: number): string {
    switch (readyState) {
      case WebSocket.CONNECTING: return 'CONNECTING (0)';
      case WebSocket.OPEN: return 'OPEN (1)';
      case WebSocket.CLOSING: return 'CLOSING (2)';
      case WebSocket.CLOSED: return 'CLOSED (3)';
      default: return `UNKNOWN (${readyState})`;
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
        console.log('✅ [StreamingClient] Received completion message from server');
        this.completionReceived = true;
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
    console.log('🔌 [StreamingClient] Manual disconnect requested');
    this.isManualClose = true;
    this.completionReceived = false; // Reset completion flag
    
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    if (this.websocket) {
      console.log('🔌 [StreamingClient] Closing WebSocket, readyState:', this.getReadyStateText(this.websocket.readyState));
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