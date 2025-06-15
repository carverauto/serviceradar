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

// GetTodaysSweepResults queries for today's sweep results
func (s *SweepResultsQuery) GetTodaysSweepResults(ctx context.Context) ([]SweepResult, error) {
	query := "show sweep_results where date(timestamp) = TODAY and discovery_source = \"sweep\""

	log.Println("Executing SRQL query for today's sweep results:", query)

	return s.executeSweepQuery(ctx, query, 1000) // Get up to 1000 results
}

// GetSweepResultsForIPs queries sweep results for specific IP addresses
func (s *SweepResultsQuery) GetSweepResultsForIPs(ctx context.Context, ips []string) ([]SweepResult, error) {
	if len(ips) == 0 {
		return []SweepResult{}, nil
	}

	// Build IP list for the IN clause
	ipList := ""
	for i, ip := range ips {
		if i > 0 {
			ipList += ", "
		}
		ipList += fmt.Sprintf("'%s'", ip)
	}

	query := fmt.Sprintf("show sweep_results where ip IN (%s) and date(timestamp) = TODAY", ipList)
	return s.executeSweepQuery(ctx, query, len(ips)*2) // Allow for multiple results per IP
}

// GetRecentSweepResults queries for sweep results within a time range
func (s *SweepResultsQuery) GetRecentSweepResults(ctx context.Context, hours int) ([]SweepResult, error) {
	// For now, we'll use TODAY as SRQL doesn't support relative time queries yet
	// In the future, this could be enhanced to support actual time ranges
	query := "show sweep_results where date(timestamp) = TODAY order by timestamp desc"
	return s.executeSweepQuery(ctx, query, 1000)
}

// executeSweepQuery executes an SRQL query and returns sweep results
func (s *SweepResultsQuery) executeSweepQuery(ctx context.Context, query string, limit int) ([]SweepResult, error) {
	var allResults []SweepResult
	cursor := ""

	for {
		// Prepare the query request
		queryReq := QueryRequest{
			Query:  query,
			Limit:  limit,
			Cursor: cursor,
		}

		// Execute the query
		response, err := s.executeQuery(ctx, queryReq)
		if err != nil {
			return nil, fmt.Errorf("failed to execute query: %w", err)
		}

		// Convert results
		results, err := s.convertToSweepResults(response.Results)
		if err != nil {
			return nil, fmt.Errorf("failed to convert results: %w", err)
		}

		allResults = append(allResults, results...)

		// Check if there are more results
		if response.Pagination.NextCursor == "" || len(results) == 0 {
			break
		}

		cursor = response.Pagination.NextCursor
	}

	return allResults, nil
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
func (s *SweepResultsQuery) convertToSweepResults(rawResults []map[string]interface{}) ([]SweepResult, error) {
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

	return results, nil
}

// GetAvailabilityStats returns availability statistics for the given IPs
func (s *SweepResultsQuery) GetAvailabilityStats(ctx context.Context, ips []string) (map[string]bool, error) {
	results, err := s.GetSweepResultsForIPs(ctx, ips)
	if err != nil {
		return nil, err
	}

	// Create a map of IP to availability status
	// Use the most recent result for each IP
	availabilityMap := make(map[string]bool)
	latestTimestamp := make(map[string]time.Time)

	for _, result := range results {
		if existing, exists := latestTimestamp[result.IP]; !exists || result.Timestamp.After(existing) {
			availabilityMap[result.IP] = result.Available
			latestTimestamp[result.IP] = result.Timestamp
		}
	}

	return availabilityMap, nil
}
