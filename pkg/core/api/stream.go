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

	// Handle authentication for WebSocket connections
	// WebSocket supports cookies, so we can check for auth tokens in cookies
	if !s.handleWebSocketAuth(w, r) {
		return
	}

	// Upgrade HTTP connection to WebSocket
	upgrader := websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin: func(r *http.Request) bool {
			return s.checkWebSocketOrigin(r)
		},
	}
	conn, err := upgrader.Upgrade(w, r, nil)

	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to upgrade to WebSocket")
		return
	}

	defer conn.Close()

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
	if streamErr := s.streamQueryResults(ctx, conn, streamingSQL); streamErr != nil {
		s.logger.Error().Err(streamErr).Msg("Streaming query failed")

		if sendErr := sendErrorMessage(conn, fmt.Sprintf("Query execution failed: %v", streamErr)); sendErr != nil {
			s.logger.Error().Err(sendErr).Msg("Failed to send error message")
		}
	}

	// Send completion message
	err = sendCompletionMessage(conn)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to send completion message")

		return
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

// streamQueryResults executes the SQL query and streams results to the WebSocket
func (s *APIServer) streamQueryResults(ctx context.Context, conn *websocket.Conn, sqlQuery string) error {
	// Get database connection
	dbConn, err := s.getStreamingDB()
	if err != nil {
		return fmt.Errorf("failed to get database connection: %w", err)
	}

	// Execute the streaming query using the proton connection
	rows, err := dbConn.Query(ctx, sqlQuery)
	if err != nil {
		return fmt.Errorf("failed to execute query: %w", err)
	}
	defer rows.Close()

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

	// Stream rows to the WebSocket
	rowCount := 0
	ticker := time.NewTicker(30 * time.Second) // Ping ticker for keepalive

	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			// Context canceled (client disconnected or server shutdown)
			return ctx.Err()

		case <-ticker.C:
			// Send ping to keep connection alive
			if err := sendPingMessage(conn); err != nil {
				return err
			}

		default:
			// Check if there's a next row
			if !rows.Next() {
				// Check for iteration error
				if err := rows.Err(); err != nil {
					// Context cancellation is expected when client disconnects
					if err == context.Canceled {
						s.logger.Info().Msg("Streaming query canceled by client disconnect")
						return nil
					}
					return fmt.Errorf("row iteration error: %w", err)
				}

				// No more rows currently available
				// For streaming queries, we should wait for new data rather than ending
				// Sleep briefly to avoid tight loop, then continue checking
				time.Sleep(100 * time.Millisecond)
				continue
			}

			// Scan the row with proper types
			if err := rows.Scan(scanVars...); err != nil {
				s.logger.Warn().Err(err).Msg("Failed to scan row")
				continue
			}

			// Convert row to map using the same logic as db.convertRow
			rowData := convertStreamRow(columns, scanVars)

			// Send data message
			if err := sendDataMessage(conn, rowData); err != nil {
				return err
			}

			rowCount++

			// Small yield to prevent tight loop
			if rowCount%100 == 0 {
				time.Sleep(10 * time.Millisecond)
			}
		}
	}
}

// handleClientMessages reads messages from the client (for disconnect detection)
func (s *APIServer) handleClientMessages(ctx context.Context, conn *websocket.Conn, cancel context.CancelFunc) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
			// Set read deadline to detect disconnection
			if err := conn.SetReadDeadline(time.Now().Add(60 * time.Second)); err != nil {
				s.logger.Warn().Err(err).Msg("Failed to set read deadline")
			}

			messageType, _, err := conn.ReadMessage()
			if err != nil {
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
					s.logger.Warn().Err(err).Msg("WebSocket closed unexpectedly")
				}

				cancel() // Cancel the streaming context

				return
			}

			// Handle control messages (ping/pong handled automatically by gorilla/websocket)
			if messageType == websocket.CloseMessage {
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

	return conn.WriteJSON(msg)
}

func sendErrorMessage(conn *websocket.Conn, errMsg string) error {
	msg := StreamMessage{
		Type:      "error",
		Error:     errMsg,
		Timestamp: time.Now(),
	}

	return conn.WriteJSON(msg)
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

	return conn.WriteJSON(msg)
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
