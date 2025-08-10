/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package api provides the HTTP API server for ServiceRadar
package api

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"reflect"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/srql"
	"github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser"
	"github.com/gorilla/websocket"
	"github.com/timeplus-io/proton-go-driver/v2"
)

// StreamMessage represents a message sent over the WebSocket
type StreamMessage struct {
	Type      string                 `json:"type"` // "data", "error", "complete", "ping"
	Data      map[string]interface{} `json:"data,omitempty"`
	Error     string                 `json:"error,omitempty"`
	Timestamp time.Time              `json:"timestamp"`
}

const (
	// Time allowed to write a message to the peer.
	writeWait = 10 * time.Second
	// Time allowed to read the next pong message from the peer.
	pongWait = 60 * time.Second
	// Send pings to peer with this period. Must be less than pongWait.
	pingPeriod = (pongWait * 9) / 10
)

// handleStreamQuery handles WebSocket connections for streaming SRQL queries
func (s *APIServer) handleStreamQuery(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("query")
	if query == "" {
		writeError(w, "Query parameter is required", http.StatusBadRequest)
		return
	}

	upgrader := websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin:     func(r *http.Request) bool { return s.checkWebSocketOrigin(r) },
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to upgrade to WebSocket")
		return
	}
	defer conn.Close()

	if !s.authenticateWebSocketConnection(r) {
		conn.WriteJSON(StreamMessage{Type: "error", Error: "Authentication required", Timestamp: time.Now()})
		return
	}

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	// Channel for messages to be sent to the client.
	sendCh := make(chan StreamMessage, 256)

	// Start the writer goroutine. It is the ONLY goroutine that writes to the connection.
	go writer(conn, sendCh)

	// Start the reader goroutine to handle pongs and detect disconnects.
	go reader(conn, cancel)

	streamingSQL, _, err := prepareStreamingQuery(query)
	if err != nil {
		sendCh <- StreamMessage{Type: "error", Error: fmt.Sprintf("Failed to prepare query: %v", err), Timestamp: time.Now()}
		return
	}

	s.logger.Info().Str("query", query).Str("sql", streamingSQL).Msg("Starting streaming query")

	s.streamQueryResults(ctx, streamingSQL, sendCh)

	s.logger.Info().Str("remote_addr", conn.RemoteAddr().String()).Msg("WebSocket streaming handler finished")
}

// writer is a dedicated goroutine that pumps messages from the sendCh to the WebSocket connection.
func writer(conn *websocket.Conn, sendCh <-chan StreamMessage) {
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()
	defer conn.Close()

	for {
		select {
		case message, ok := <-sendCh:
			conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				// The channel was closed.
				conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := conn.WriteJSON(message); err != nil {
				return
			}
		case <-ticker.C:
			conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// reader pumps messages from the WebSocket connection to discard them, handles pong messages, and detects disconnects.
func reader(conn *websocket.Conn, cancel context.CancelFunc) {
	defer cancel()
	defer conn.Close()
	conn.SetReadLimit(512)
	conn.SetReadDeadline(time.Now().Add(pongWait))
	conn.SetPongHandler(func(string) error { conn.SetReadDeadline(time.Now().Add(pongWait)); return nil })
	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			break
		}
	}
}

// streamQueryResults executes the database query and sends results to the sendCh.
func (s *APIServer) streamQueryResults(ctx context.Context, sqlQuery string, sendCh chan<- StreamMessage) {
	// When this function exits, close the send channel to signal the writer to stop.
	defer close(sendCh)

	dbConn, err := s.getStreamingDB()
	if err != nil {
		sendCh <- StreamMessage{Type: "error", Error: fmt.Sprintf("Failed to get db connection: %v", err), Timestamp: time.Now()}
		return
	}

	rows, err := dbConn.Query(ctx, sqlQuery)
	if err != nil {
		sendCh <- StreamMessage{Type: "error", Error: fmt.Sprintf("Failed to execute query: %v", err), Timestamp: time.Now()}
		return
	}
	defer rows.Close()

	columnTypes := rows.ColumnTypes()
	columns := make([]string, len(columnTypes))
	for i, ct := range columnTypes {
		columns[i] = ct.Name()
	}

	for {
		// Check if the context has been canceled (e.g., client disconnected).
		select {
		case <-ctx.Done():
			s.logger.Info().Err(ctx.Err()).Msg("Streaming context canceled, stopping database query.")
			return
		default:
		}

		if !rows.Next() {
			break // Exit loop if no more rows or an error occurred.
		}

		scanVars := make([]interface{}, len(columnTypes))
		for i := range columnTypes {
			scanVars[i] = reflect.New(columnTypes[i].ScanType()).Interface()
		}

		if err := rows.Scan(scanVars...); err != nil {
			sendCh <- StreamMessage{Type: "error", Error: fmt.Sprintf("Failed to scan row: %v", err), Timestamp: time.Now()}
			return
		}

		sendCh <- StreamMessage{Type: "data", Data: convertStreamRow(columns, scanVars), Timestamp: time.Now()}
	}

	if err := rows.Err(); err != nil {
		sendCh <- StreamMessage{Type: "error", Error: fmt.Sprintf("Database iteration error: %v", err), Timestamp: time.Now()}
	} else {
		sendCh <- StreamMessage{Type: "complete", Timestamp: time.Now()}
		s.logger.Info().Msg("✅ Database stream finished successfully.")
	}
}

// prepareStreamingQuery parses an SRQL query and prepares it for streaming execution
func prepareStreamingQuery(srqlQuery string) (string, models.EntityType, error) {
	// Parse the SRQL query
	parsedQuery, err := srql.NewParser().Parse(srqlQuery)
	if err != nil {
		return "", "", fmt.Errorf("failed to parse SRQL query: %w", err)
	}

	// Create a streaming translator (Proton without table() wrapper)
	translator := parser.NewTranslator(parser.Proton)

	// Transform the query (entity type transformations)
	translator.TransformQuery(parsedQuery)

	// Force the query to be treated as a STREAM type (not Show) for infinite streaming
	// This ensures no LIMIT is applied and the query runs continuously
	parsedQuery.Type = models.Stream

	// Remove any explicit limit for streaming - we want infinite results
	parsedQuery.HasLimit = false
	parsedQuery.Limit = 0

	// Translate to SQL for streaming (without table() wrapper)
	sql, err := translator.TranslateForStreaming(parsedQuery)
	if err != nil {
		return "", "", fmt.Errorf("failed to translate query: %w", err)
	}

	return sql, parsedQuery.Entity, nil
}

// handleClientMessages reads messages from the client and handles disconnects.
// This new version uses the standard WebSocket ping/pong keepalive mechanism.
func (s *APIServer) handleClientMessages(ctx context.Context, conn *websocket.Conn, cancel context.CancelFunc) {
	defer func() {
		s.logger.Info().Str("client_addr", conn.RemoteAddr().String()).Msg("WebSocket client handler finished, canceling stream context.")
		cancel() // Ensure the streaming context is canceled when this goroutine exits.
	}()

	// Define the wait time for a pong response from the client.
	const pongWait = 60 * time.Second
	if err := conn.SetReadDeadline(time.Now().Add(pongWait)); err != nil {
		s.logger.Error().Err(err).Str("client_addr", conn.RemoteAddr().String()).Msg("Failed to set initial read deadline")
		return
	}

	// The PongHandler resets the read deadline every time a pong is received.
	conn.SetPongHandler(func(string) error {
		s.logger.Debug().Str("client_addr", conn.RemoteAddr().String()).Msg("Pong received, extending read deadline.")
		return conn.SetReadDeadline(time.Now().Add(pongWait))
	})

	// This loop blocks on ReadMessage(). It will only unblock if the client
	// sends a message or if the read deadline is exceeded (indicating a disconnect).
	for {
		messageType, _, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				s.logger.Error().Err(err).Str("client_addr", conn.RemoteAddr().String()).Msg("Unexpected WebSocket close error")
			} else {
				s.logger.Info().Err(err).Str("client_addr", conn.RemoteAddr().String()).Msg("WebSocket client disconnected or timed out")
			}
			// Exit the loop and trigger the deferred cancel().
			return
		}

		// If a close message is received, exit cleanly.
		if messageType == websocket.CloseMessage {
			s.logger.Info().Str("client_addr", conn.RemoteAddr().String()).Msg("Client sent a close message.")
			return
		}
	}
}

// getStreamingDB returns a database connection suitable for streaming
func (s *APIServer) getStreamingDB() (proton.Conn, error) {
	if s.dbService == nil {
		return nil, fmt.Errorf("database service not configured")
	}

	// Get the streaming connection from the database service
	conn, err := s.dbService.GetStreamingConnection()
	if err != nil {
		return nil, fmt.Errorf("failed to get streaming connection: %w", err)
	}

	// Type assert to proton.Conn
	protonConn, ok := conn.(proton.Conn)
	if !ok {
		return nil, fmt.Errorf("unexpected connection type: %T", conn)
	}

	return protonConn, nil
}

// Message sending helper functions

func sendDataMessage(conn *websocket.Conn, data map[string]interface{}) error {
	msg := StreamMessage{
		Type:      "data",
		Data:      data,
		Timestamp: time.Now(),
	}

	if err := conn.WriteJSON(msg); err != nil {
		// Don't log every write error as it can flood logs, but return the error
		// The caller will log the error with more context
		return fmt.Errorf("failed to write JSON message: %w", err)
	}

	return nil
}

func sendErrorMessage(conn *websocket.Conn, errMsg string) error {
	msg := StreamMessage{
		Type:      "error",
		Error:     errMsg,
		Timestamp: time.Now(),
	}

	if err := conn.WriteJSON(msg); err != nil {
		return fmt.Errorf("failed to write error message: %w", err)
	}

	return nil
}

func sendCompletionMessage(conn *websocket.Conn) error {
	msg := StreamMessage{
		Type:      "complete",
		Timestamp: time.Now(),
	}

	return conn.WriteJSON(msg)
}

func sendPingMessage(conn *websocket.Conn) error {
	msg := StreamMessage{
		Type:      "ping",
		Timestamp: time.Now(),
	}

	if err := conn.WriteJSON(msg); err != nil {
		return fmt.Errorf("failed to write ping message: %w", err)
	}

	return nil
}

// handleWebSocketAuth handles authentication for WebSocket connections
// Returns true if authentication is successful or not required, false otherwise
func (s *APIServer) handleWebSocketAuth(w http.ResponseWriter, r *http.Request) bool {
	// Try Bearer token authentication (from Authorization header)
	authHeader := r.Header.Get("Authorization")
	if strings.HasPrefix(authHeader, "Bearer ") {
		token := strings.TrimPrefix(authHeader, "Bearer ")
		if s.authService != nil {
			user, err := s.authService.VerifyToken(r.Context(), token)
			if err != nil {
				writeError(w, "Invalid bearer token", http.StatusUnauthorized)
				return false
			}
			// Add user to context
			*r = *r.WithContext(context.WithValue(r.Context(), "user", user))
			return true
		}
	}

	// Try Bearer token from cookies (more secure for WebSocket)
	// Check for accessToken cookie (used by the web app)
	if cookie, err := r.Cookie("accessToken"); err == nil && s.authService != nil {
		user, err := s.authService.VerifyToken(r.Context(), cookie.Value)
		if err == nil {
			// Add user to context
			*r = *r.WithContext(context.WithValue(r.Context(), "user", user))
			return true
		}
	}
	// Also check legacy access_token cookie name
	if cookie, err := r.Cookie("access_token"); err == nil && s.authService != nil {
		user, err := s.authService.VerifyToken(r.Context(), cookie.Value)
		if err == nil {
			// Add user to context
			*r = *r.WithContext(context.WithValue(r.Context(), "user", user))
			return true
		}
	}

	// Try API key authentication (header and cookie only - no query parameters for security)
	apiKey := r.Header.Get("X-API-Key")
	if apiKey == "" {
		// Also check for API key in cookies
		if cookie, err := r.Cookie("api_key"); err == nil {
			apiKey = cookie.Value
		}
	}
	if apiKey != "" && s.isAPIKeyValid(apiKey) {
		return true
	}

	// Check if authentication is required
	if s.isAuthRequired() {
		s.logAuthFailure("WebSocket authentication required but not provided")
		writeError(w, "Authentication required", http.StatusUnauthorized)
		return false
	}

	// Development mode - no auth configured
	s.logAuthFailure("No authentication configured for WebSocket - allowing request (development mode)")
	return true
}

// authenticateWebSocketConnection validates authentication without interfering with WebSocket handshake
// Returns true if authentication is successful or not required, false otherwise
func (s *APIServer) authenticateWebSocketConnection(r *http.Request) bool {
	// Try Bearer token authentication (from Authorization header)
	authHeader := r.Header.Get("Authorization")
	if strings.HasPrefix(authHeader, "Bearer ") {
		token := strings.TrimPrefix(authHeader, "Bearer ")
		if s.authService != nil {
			user, err := s.authService.VerifyToken(r.Context(), token)
			if err != nil {
				s.logger.Warn().Err(err).Msg("WebSocket bearer token authentication failed")
				return false
			}
			// Add user to context
			*r = *r.WithContext(context.WithValue(r.Context(), "user", user))
			return true
		}
	}

	// Try Bearer token from cookies (more secure for WebSocket)
	// Check for accessToken cookie (used by the web app)
	if cookie, err := r.Cookie("accessToken"); err == nil && s.authService != nil {
		user, err := s.authService.VerifyToken(r.Context(), cookie.Value)
		if err == nil {
			// Add user to context
			*r = *r.WithContext(context.WithValue(r.Context(), "user", user))
			s.logger.Debug().Msg("WebSocket authenticated via accessToken cookie")
			return true
		}
		s.logger.Warn().Err(err).Msg("WebSocket accessToken cookie authentication failed")
	}

	// Also check legacy access_token cookie name
	if cookie, err := r.Cookie("access_token"); err == nil && s.authService != nil {
		user, err := s.authService.VerifyToken(r.Context(), cookie.Value)
		if err == nil {
			// Add user to context
			*r = *r.WithContext(context.WithValue(r.Context(), "user", user))
			s.logger.Debug().Msg("WebSocket authenticated via access_token cookie")
			return true
		}
		s.logger.Warn().Err(err).Msg("WebSocket access_token cookie authentication failed")
	}

	// Try API key authentication (header and cookie only - no query parameters for security)
	apiKey := r.Header.Get("X-API-Key")
	if apiKey == "" {
		// Also check for API key in cookies
		if cookie, err := r.Cookie("api_key"); err == nil {
			apiKey = cookie.Value
		}
	}
	if apiKey != "" && s.isAPIKeyValid(apiKey) {
		s.logger.Debug().Msg("WebSocket authenticated via API key")
		return true
	}

	// Check if authentication is required
	if s.isAuthRequired() {
		s.logger.Warn().Msg("WebSocket authentication required but not provided")
		return false
	}

	// Development mode - no auth configured
	s.logger.Debug().Msg("No authentication configured for WebSocket - allowing request (development mode)")
	return true
}

// isAPIKeyValid checks if the provided API key is valid
func (s *APIServer) isAPIKeyValid(providedKey string) bool {
	configuredKey := os.Getenv("API_KEY")
	return configuredKey != "" && providedKey == configuredKey
}

// convertStreamRow converts scanned row values to a map, handling type dereferencing
// This uses the same logic as db.convertRow for consistency
func convertStreamRow(columns []string, scanVars []interface{}) map[string]interface{} {
	row := make(map[string]interface{}, len(columns))

	for i, col := range columns {
		row[col] = dereferenceValue(scanVars[i])
	}

	return row
}

// checkWebSocketOrigin validates WebSocket origin against CORS configuration
func (s *APIServer) checkWebSocketOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")

	// If there's no Origin header, allow the connection (same as middleware logic)
	if origin == "" {
		return true
	}

	// Check if the request origin is in the allowed list
	for _, allowedOrigin := range s.corsConfig.AllowedOrigins {
		if allowedOrigin == origin || allowedOrigin == "*" {
			return true
		}
	}

	// Log the rejected origin for debugging
	if s.logger != nil {
		s.logger.Warn().
			Str("origin", origin).
			Interface("allowed_origins", s.corsConfig.AllowedOrigins).
			Msg("WebSocket CORS: Origin not allowed")
	}

	return false
}

// dereferenceValue dereferences a scanned value and returns its concrete type
// This mirrors the db.dereferenceValue function for consistency
func dereferenceValue(v interface{}) interface{} {
	switch val := v.(type) {
	case *string:
		return *val
	case *uint8:
		return *val
	case *uint64:
		return *val
	case *int64:
		return *val
	case *float64:
		return *val
	case *time.Time:
		return val.Format(time.RFC3339)
	case *bool:
		return *val
	default:
		// Handle non-pointer types or unexpected types
		if reflect.TypeOf(v).Kind() == reflect.Ptr {
			if reflect.ValueOf(v).IsNil() {
				return nil
			}

			val := reflect.ValueOf(v).Elem().Interface()
			// Handle time.Time specially for JSON serialization
			if t, ok := val.(time.Time); ok {
				return t.Format(time.RFC3339)
			}

			return val
		}

		return v
	}
}
