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

// handleStreamQuery handles WebSocket connections for streaming SRQL queries
func (s *APIServer) handleStreamQuery(w http.ResponseWriter, r *http.Request) {
	// Get query from URL parameter
	query := r.URL.Query().Get("query")
	if query == "" {
		writeError(w, "Query parameter is required", http.StatusBadRequest)
		return
	}

	s.logger.Debug().
		Str("query", query).
		Str("remote_addr", r.RemoteAddr).
		Str("user_agent", r.UserAgent()).
		Str("origin", r.Header.Get("Origin")).
		Msg("WebSocket streaming request received")

	// Upgrade HTTP connection to WebSocket first
	// Authentication will be handled after successful upgrade
	upgrader := websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin: func(r *http.Request) bool {
			return s.checkWebSocketOrigin(r)
		},
	}
	conn, err := upgrader.Upgrade(w, r, nil)

	if err != nil {
		s.logger.Error().
			Err(err).
			Str("remote_addr", r.RemoteAddr).
			Str("origin", r.Header.Get("Origin")).
			Msg("Failed to upgrade to WebSocket")
		return
	}

	s.logger.Info().
		Str("remote_addr", r.RemoteAddr).
		Str("query", query).
		Msg("WebSocket connection established successfully")

	defer func() {
		s.logger.Debug().
			Str("remote_addr", r.RemoteAddr).
			Msg("Closing WebSocket connection")
		conn.Close()
	}()

	// Handle authentication after WebSocket upgrade
	// This way we don't interfere with the WebSocket handshake
	if !s.authenticateWebSocketConnection(r) {
		// Send authentication error through WebSocket
		sendErrorMessage(conn, "Authentication required")
		return
	}

	// Create cancellable context for the streaming operation
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	// Start goroutine to handle client disconnect
	go s.handleClientMessages(ctx, conn, cancel)

	// Parse and prepare the streaming query
	streamingSQL, entity, err := prepareStreamingQuery(query)
	if err != nil {
		if sendErr := sendErrorMessage(conn, fmt.Sprintf("Failed to prepare query: %v", err)); sendErr != nil {
			s.logger.Error().Err(sendErr).Msg("Failed to send error message")
		}

		return
	}

	s.logger.Info().
		Str("query", query).
		Str("sql", streamingSQL).
		Str("entity", string(entity)).
		Msg("Starting streaming query")

	// Execute the streaming query
	s.logger.Info().
		Str("query", query).
		Str("sql", streamingSQL).
		Str("remote_addr", r.RemoteAddr).
		Msg("Starting WebSocket streaming query execution")

	if streamErr := s.streamQueryResults(ctx, conn, streamingSQL, r.RemoteAddr); streamErr != nil {
		s.logger.Error().
			Err(streamErr).
			Str("query", query).
			Str("sql", streamingSQL).
			Str("remote_addr", r.RemoteAddr).
			Msg("Streaming query failed")

		if sendErr := sendErrorMessage(conn, fmt.Sprintf("Query execution failed: %v", streamErr)); sendErr != nil {
			s.logger.Error().
				Err(sendErr).
				Str("remote_addr", r.RemoteAddr).
				Msg("Failed to send error message")
		}
	}

	// The streaming function should have already sent a completion message if it ended normally
	s.logger.Info().
		Str("remote_addr", r.RemoteAddr).
		Msg("WebSocket streaming handler finished successfully")
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

// streamQueryResults executes the SQL query and streams results to the WebSocket
func (s *APIServer) streamQueryResults(ctx context.Context, conn *websocket.Conn, sqlQuery string, clientAddr string) error {
	s.logger.Debug().
		Str("client_addr", clientAddr).
		Str("sql", sqlQuery).
		Msg("Starting database query execution for streaming")

	// Get database connection
	dbConn, err := s.getStreamingDB()
	if err != nil {
		s.logger.Error().
			Err(err).
			Str("client_addr", clientAddr).
			Msg("Failed to get streaming database connection")
		return fmt.Errorf("failed to get database connection: %w", err)
	}

	// Execute the streaming query using the proton connection
	s.logger.Debug().
		Str("client_addr", clientAddr).
		Str("sql", sqlQuery).
		Msg("Executing streaming query against Proton")

	rows, err := dbConn.Query(ctx, sqlQuery)
	if err != nil {
		s.logger.Error().
			Err(err).
			Str("client_addr", clientAddr).
			Str("sql", sqlQuery).
			Msg("Failed to execute streaming query")
		return fmt.Errorf("failed to execute query: %w", err)
	}
	defer func() {
		s.logger.Debug().
			Str("client_addr", clientAddr).
			Msg("Closing database result rows")
		rows.Close()
	}()

	// Get column information with proper types
	columnTypes := rows.ColumnTypes()
	columns := make([]string, len(columnTypes))

	for i, ct := range columnTypes {
		columns[i] = ct.Name()
	}

	// Create properly typed scan variables like the regular query code
	scanVars := make([]interface{}, len(columnTypes))
	for i := range columnTypes {
		scanVars[i] = reflect.New(columnTypes[i].ScanType()).Interface()
	}

	s.logger.Info().
		Str("client_addr", clientAddr).
		Int("column_count", len(columns)).
		Interface("column_names", columns).
		Msg("Starting WebSocket data streaming loop")

	// Stream rows to the WebSocket
	rowCount := 0
	sendCount := 0
	errorCount := 0
	lastProgressTime := time.Now()
	ticker := time.NewTicker(30 * time.Second) // Ping ticker for keepalive

	defer func() {
		s.logger.Info().
			Str("client_addr", clientAddr).
			Int("final_row_count", rowCount).
			Int("final_send_count", sendCount).
			Int("error_count", errorCount).
			Msg("WebSocket streaming loop ended")
		ticker.Stop()
	}()

	for {
		select {
		case <-ctx.Done():
			// Context canceled (client disconnected or server shutdown)
			s.logger.Info().
				Str("client_addr", clientAddr).
				Int("row_count", rowCount).
				Int("send_count", sendCount).
				Err(ctx.Err()).
				Msg("WebSocket streaming context canceled")
			return ctx.Err()

		case <-ticker.C:
			// Send ping to keep connection alive
			s.logger.Debug().
				Str("client_addr", clientAddr).
				Int("row_count", rowCount).
				Int("send_count", sendCount).
				Msg("Sending WebSocket keepalive ping")
			if err := sendPingMessage(conn); err != nil {
				s.logger.Error().
					Err(err).
					Str("client_addr", clientAddr).
					Msg("Failed to send WebSocket ping - connection likely broken")
				return fmt.Errorf("ping failed: %w", err)
			}

		default:
			// Check if there's a next row
			if !rows.Next() {
				// Check for iteration error
				if err := rows.Err(); err != nil {
					// Context cancellation is expected when client disconnects
					if err == context.Canceled {
						s.logger.Info().
							Str("client_addr", clientAddr).
							Int("final_row_count", rowCount).
							Msg("Streaming query canceled by client disconnect")
						return nil
					}
					s.logger.Error().
						Err(err).
						Str("client_addr", clientAddr).
						Int("row_count", rowCount).
						Msg("Database row iteration error during streaming")
					return fmt.Errorf("row iteration error: %w", err)
				}

				// IMPORTANT: This is likely the root cause of our 1006 issues!
				// When Proton finishes a batch (often around 500 records), rows.Next() returns false
				// This is NOT an error - it's normal behavior for batch processing
				// We should close the connection cleanly rather than waiting indefinitely
				
				s.logger.Info().
					Str("client_addr", clientAddr).
					Int("final_row_count", rowCount).
					Int("final_send_count", sendCount).
					Msg("✅ Proton query batch completed - this is normal! Closing connection cleanly.")

				// Send completion message to client
				if err := sendCompletionMessage(conn); err != nil {
					s.logger.Warn().
						Err(err).
						Str("client_addr", clientAddr).
						Msg("Failed to send completion message")
				}

				// Return cleanly - this should result in a normal WebSocket close, not 1006
				return nil
			}

			// Scan the row with proper types
			if err := rows.Scan(scanVars...); err != nil {
				errorCount++
				s.logger.Warn().
					Err(err).
					Str("client_addr", clientAddr).
					Int("row_count", rowCount).
					Int("error_count", errorCount).
					Msg("Failed to scan row during streaming")
				continue
			}

			// Convert row to map using the same logic as db.convertRow
			rowData := convertStreamRow(columns, scanVars)
			rowCount++

			// Send data message
			if err := sendDataMessage(conn, rowData); err != nil {
				s.logger.Error().
					Err(err).
					Str("client_addr", clientAddr).
					Int("row_count", rowCount).
					Int("send_count", sendCount).
					Msg("Failed to send data message - WebSocket connection broken")
				return fmt.Errorf("failed to send data message: %w", err)
			}
			sendCount++

			// Log progress every 50 rows to better track the 500 limit issue
			if rowCount%50 == 0 {
				elapsed := time.Since(lastProgressTime)
				rate := float64(50) / elapsed.Seconds()
				s.logger.Info().
					Str("client_addr", clientAddr).
					Int("row_count", rowCount).
					Int("send_count", sendCount).
					Int("error_count", errorCount).
					Float64("rows_per_sec", rate).
					Str("sql", sqlQuery).
					Msg("WebSocket streaming progress")
				lastProgressTime = time.Now()
			}

			// Special logging around the 500 limit to diagnose the issue
			if rowCount == 400 {
				s.logger.Warn().
					Str("client_addr", clientAddr).
					Int("row_count", rowCount).
					Str("sql", sqlQuery).
					Msg("⚠️ APPROACHING 500 ROW LIMIT - monitoring for connection issues")
			} else if rowCount == 495 {
				s.logger.Warn().
					Str("client_addr", clientAddr).
					Int("row_count", rowCount).
					Msg("🔴 VERY CLOSE TO 500 LIMIT - next few messages critical")
			} else if rowCount == 500 {
				s.logger.Error().
					Str("client_addr", clientAddr).
					Int("row_count", rowCount).
					Int("send_count", sendCount).
					Str("sql", sqlQuery).
					Msg("🚨 HIT 500 ROW LIMIT - MONITORING FOR CONNECTION DROP")
			} else if rowCount > 500 && rowCount <= 520 {
				s.logger.Info().
					Str("client_addr", clientAddr).
					Int("row_count", rowCount).
					Msg("🎉 SUCCESSFULLY PASSED 500 LIMIT - connection still alive!")
			} else if rowCount == 1000 {
				s.logger.Info().
					Str("client_addr", clientAddr).
					Int("row_count", rowCount).
					Msg("🏆 REACHED 1000 ROWS - streaming working well!")
			}
		}
	}
}

// handleClientMessages reads messages from the client (for disconnect detection)
func (s *APIServer) handleClientMessages(ctx context.Context, conn *websocket.Conn, cancel context.CancelFunc) {
	start := time.Now()
	clientAddr := conn.RemoteAddr().String()

	s.logger.Debug().
		Str("client_addr", clientAddr).
		Msg("Starting WebSocket client message handler")

	defer func() {
		duration := time.Since(start)
		s.logger.Info().
			Str("client_addr", clientAddr).
			Dur("duration", duration).
			Msg("WebSocket client message handler ended")
	}()

	for {
		select {
		case <-ctx.Done():
			s.logger.Debug().
				Str("client_addr", clientAddr).
				Msg("WebSocket client handler context canceled")
			return
		default:
			// Set read deadline to detect disconnection
			if err := conn.SetReadDeadline(time.Now().Add(60 * time.Second)); err != nil {
				s.logger.Warn().
					Err(err).
					Str("client_addr", clientAddr).
					Msg("Failed to set WebSocket read deadline")
			}

			messageType, message, err := conn.ReadMessage()
			if err != nil {
				duration := time.Since(start)

				// Check if this is an unexpected close error
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure, websocket.CloseNormalClosure) {
					s.logger.Error().
						Err(err).
						Str("client_addr", clientAddr).
						Dur("connection_duration", duration).
						Msg("🚨 UNEXPECTED WebSocket close error detected")
				} else if closeErr, ok := err.(*websocket.CloseError); ok {
					s.logger.Info().
						Int("close_code", closeErr.Code).
						Str("close_text", closeErr.Text).
						Str("client_addr", clientAddr).
						Dur("connection_duration", duration).
						Msg("🔴 WebSocket closed with specific code")

					// Log specific close codes to help diagnose 1006 errors
					if closeErr.Code == 1006 {
						s.logger.Error().
							Str("client_addr", clientAddr).
							Dur("connection_duration", duration).
							Msg("🚨 ABNORMAL CLOSURE (1006) - This is the main issue we're investigating!")
					}
				} else {
					s.logger.Warn().
						Err(err).
						Str("client_addr", clientAddr).
						Dur("connection_duration", duration).
						Msg("WebSocket read error (not a close error)")
				}

				cancel() // Cancel the streaming context
				return
			}

			// Log received message for debugging
			s.logger.Debug().
				Str("client_addr", clientAddr).
				Int("message_type", messageType).
				Int("message_length", len(message)).
				Msg("Received WebSocket message from client")

			// Handle control messages (ping/pong handled automatically by gorilla/websocket)
			if messageType == websocket.CloseMessage {
				s.logger.Info().
					Str("client_addr", clientAddr).
					Msg("Received WebSocket close message from client")
				cancel()
				return
			}
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
