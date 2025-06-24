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

// Package armis pkg/sync/integrations/armis/sweep_results.go
package armis

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

// SweepResult represents a network sweep result
type SweepResult struct {
	IP        string    `json:"ip"`
	Available bool      `json:"available"`
	Timestamp time.Time `json:"timestamp"`
	RTT       float64   `json:"rtt,omitempty"`      // Round-trip time in milliseconds
	Port      int       `json:"port,omitempty"`     // If this was a TCP sweep
	Protocol  string    `json:"protocol,omitempty"` // "icmp" or "tcp"
	Error     string    `json:"error,omitempty"`    // Any error encountered
}

// SweepResultsQuery handles querying sweep results via SRQL
type SweepResultsQuery struct {
	APIEndpoint string // ServiceRadar API endpoint
	APIKey      string // API key for authentication
	HTTPClient  HTTPClient
}

// QueryRequest represents the SRQL query request
type QueryRequest struct {
	Query     string `json:"query"`
	Limit     int    `json:"limit,omitempty"`
	Cursor    string `json:"cursor,omitempty"`
	Direction string `json:"direction,omitempty"`
}

// QueryResponse represents the SRQL query response
type QueryResponse struct {
	Results    []map[string]interface{} `json:"results"`
	Pagination struct {
		NextCursor string `json:"next_cursor,omitempty"`
		PrevCursor string `json:"prev_cursor,omitempty"`
		Limit      int    `json:"limit"`
	} `json:"pagination"`
	Error string `json:"error,omitempty"`
}

// NewSweepResultsQuery creates a new sweep results query handler
func NewSweepResultsQuery(apiEndpoint, apiKey string, httpClient HTTPClient) *SweepResultsQuery {
	if httpClient == nil {
		httpClient = &http.Client{
			Timeout: 30 * time.Second,
		}
	}

	return &SweepResultsQuery{
		APIEndpoint: apiEndpoint,
		APIKey:      apiKey,
		HTTPClient:  httpClient,
	}
}

func (s *SweepResultsQuery) GetDeviceStatesBySource(ctx context.Context, source string) ([]DeviceState, error) {
	// Use a large limit to ensure all devices are fetched.
	query := fmt.Sprintf("show devices where discovery_sources = '%s'", source)
	limit := 10000

	var allDeviceStates []DeviceState

	cursor := ""

	for {
		queryReq := QueryRequest{
			Query:  query,
			Limit:  limit,
			Cursor: cursor,
		}

		response, err := s.executeQuery(ctx, queryReq)
		if err != nil {
			return nil, fmt.Errorf("failed to execute device query: %w", err)
		}

		// Use a new, dedicated converter for device states
		states := s.convertToDeviceStates(response.Results)
		allDeviceStates = append(allDeviceStates, states...)

		if response.Pagination.NextCursor == "" || len(states) == 0 {
			break
		}

		cursor = response.Pagination.NextCursor
	}

	return allDeviceStates, nil
}

// convertToDeviceStates parses the raw map from a 'show devices' query
// into a slice of typed DeviceState structs.
func (*SweepResultsQuery) convertToDeviceStates(rawResults []map[string]interface{}) []DeviceState {
	states := make([]DeviceState, 0, len(rawResults))

	for _, raw := range rawResults {
		state := DeviceState{}

		if ip, ok := raw["ip"].(string); ok {
			state.IP = ip
		}

		// Note the field name is 'is_available' in the devices view
		if isAvailable, ok := raw["is_available"].(bool); ok {
			state.IsAvailable = isAvailable
		}

		if meta, ok := raw["metadata"].(map[string]interface{}); ok {
			state.Metadata = meta
		}

		states = append(states, state)
	}

	return states
}

// executeQuery executes an SRQL query against the ServiceRadar API
func (s *SweepResultsQuery) executeQuery(ctx context.Context, queryReq QueryRequest) (*QueryResponse, error) {
	// Marshal the request
	reqBody, err := json.Marshal(queryReq)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal query request: %w", err)
	}

	// log the request for debugging
	log.Printf("Executing SRQL query: %s", queryReq.Query)
	// log the request body
	log.Printf("Request body: %s", string(reqBody))

	// Create the HTTP request
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/query", s.APIEndpoint),
		bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	// Set headers
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", s.APIKey)

	// Execute the request
	resp, err := s.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to execute request: %w", err)
	}
	defer resp.Body.Close()

	// Read the response
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	// Check status code
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("API returned status %d: %s", resp.StatusCode, string(body))
	}

	// Parse the response
	var queryResp QueryResponse
	if err := json.Unmarshal(body, &queryResp); err != nil {
		return nil, fmt.Errorf("failed to unmarshal response: %w", err)
	}

	if queryResp.Error != "" {
		return nil, fmt.Errorf("query error: %s", queryResp.Error)
	}

	return &queryResp, nil
}

// convertToSweepResults converts raw query results to SweepResult structs
func (*SweepResultsQuery) convertToSweepResults(rawResults []map[string]interface{}) []SweepResult {
	results := make([]SweepResult, 0, len(rawResults))

	for _, raw := range rawResults {
		result := SweepResult{}

		// Extract IP
		if ip, ok := raw["ip"].(string); ok {
			result.IP = ip
		}

		// Extract availability
		if available, ok := raw["available"].(bool); ok {
			result.Available = available
		}

		// Extract timestamp
		if ts, ok := raw["timestamp"].(string); ok {
			if parsed, err := time.Parse(time.RFC3339, ts); err == nil {
				result.Timestamp = parsed
			}
		}

		// Extract RTT (round-trip time)
		if rtt, ok := raw["rtt"].(float64); ok {
			result.RTT = rtt
		}

		// Extract port
		if port, ok := raw["port"].(float64); ok {
			result.Port = int(port)
		}

		// Extract protocol
		if protocol, ok := raw["protocol"].(string); ok {
			result.Protocol = protocol
		}

		// Extract error
		if errMsg, ok := raw["error"].(string); ok {
			result.Error = errMsg
		}

		results = append(results, result)
	}

	return results
}
