package sync

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

// GetDeviceStatesBySource queries the ServiceRadar API to get the current state of devices for a given discovery source.
func (s *SweepResultsQuery) GetDeviceStatesBySource(ctx context.Context, source string) ([]DeviceState, error) {
	// Use a large limit to ensure all devices are fetched.
	// This query finds devices that originated from the specified source and have also been seen by a sweep.
	// The `discovery_sources = 'sweep'` part is a useful heuristic to filter for devices that are actually "known" on the network.
	query := fmt.Sprintf("show devices where discovery_sources = '%s' and discovery_sources = 'sweep'", source)
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

		if deviceID, ok := raw["device_id"].(string); ok {
			state.DeviceID = deviceID
		}

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
