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
	"strings"
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

// GetTodaysSweepResults retrieves today's sweep results from ServiceRadar.
func (s *SweepResultsQuery) GetTodaysSweepResults(ctx context.Context) ([]SweepResult, error) {
	query := "show sweep_results where date(timestamp) = TODAY and discovery_source = \"sweep\""
	limit := 1000
	var all []SweepResult
	cursor := ""
	for {
		req := QueryRequest{Query: query, Limit: limit, Cursor: cursor}
		resp, err := s.executeQuery(ctx, req)
		if err != nil {
			return nil, err
		}
		results := s.convertToSweepResults(resp.Results)
		all = append(all, results...)
		if resp.Pagination.NextCursor == "" || len(results) == 0 {
			break
		}
		cursor = resp.Pagination.NextCursor
	}
	return all, nil
}

// GetSweepResultsForIPs retrieves sweep results for a list of IPs.
func (s *SweepResultsQuery) GetSweepResultsForIPs(ctx context.Context, ips []string) ([]SweepResult, error) {
	quoted := make([]string, len(ips))
	for i, ip := range ips {
		quoted[i] = fmt.Sprintf("'%s'", ip)
	}
	query := fmt.Sprintf("show sweep_results where ip IN (%s) and date(timestamp) = TODAY", strings.Join(quoted, ", "))
	limit := 1000
	var all []SweepResult
	cursor := ""
	for {
		req := QueryRequest{Query: query, Limit: limit, Cursor: cursor}
		resp, err := s.executeQuery(ctx, req)
		if err != nil {
			return nil, err
		}
		results := s.convertToSweepResults(resp.Results)
		all = append(all, results...)
		if resp.Pagination.NextCursor == "" || len(results) == 0 {
			break
		}
		cursor = resp.Pagination.NextCursor
	}
	return all, nil
}

// GetAvailabilityStats returns availability status for the given IPs using the latest result for each IP.
func (s *SweepResultsQuery) GetAvailabilityStats(ctx context.Context, ips []string) (map[string]bool, error) {
	results, err := s.GetSweepResultsForIPs(ctx, ips)
	if err != nil {
		return nil, err
	}

	avail := make(map[string]bool, len(ips))
	latest := make(map[string]time.Time, len(ips))
	for _, r := range results {
		if ts, ok := latest[r.IP]; !ok || r.Timestamp.After(ts) {
			avail[r.IP] = r.Available
			latest[r.IP] = r.Timestamp
		}
	}

	return avail, nil
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
func (s *SweepResultsQuery) convertToDeviceStates(rawResults []map[string]interface{}) []DeviceState {
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
