package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// SweepResultsQuery handles querying sweep results via SRQL
type SweepResultsQuery struct {
	APIEndpoint string // ServiceRadar API endpoint
	APIKey      string // API key for authentication
	HTTPClient  HTTPClient
	Logger      logger.Logger
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
func NewSweepResultsQuery(apiEndpoint, apiKey string, httpClient HTTPClient, log logger.Logger) *SweepResultsQuery {
	if httpClient == nil {
		httpClient = &http.Client{
			Timeout: 30 * time.Second,
		}
	}

	return &SweepResultsQuery{
		APIEndpoint: apiEndpoint,
		APIKey:      apiKey,
		HTTPClient:  httpClient,
		Logger:      log,
	}
}

// GetDeviceStatesBySource queries the ServiceRadar API to get the current state of devices for a given discovery source.
func (s *SweepResultsQuery) GetDeviceStatesBySource(ctx context.Context, source string) ([]DeviceState, error) {
	// This query finds devices that originated from the specified source and have also been seen by a sweep.
	// The `discovery_sources = 'sweep'` part is a useful heuristic to filter for devices that are actually "known" on the network.
	query := fmt.Sprintf("show devices where discovery_sources = '%s' and discovery_sources = 'sweep'", source)

	var allDeviceStates []DeviceState
	cursor := ""
	pageCount := 0
	
	// Use a reasonable page size for efficient pagination
	pageSize := 1000

	for {
		queryReq := QueryRequest{
			Query:  query,
			Limit:  pageSize,
			Cursor: cursor,
		}

		response, err := s.executeQuery(ctx, queryReq)
		if err != nil {
			return nil, fmt.Errorf("failed to execute device query on page %d: %w", pageCount, err)
		}

		states := s.convertToDeviceStates(response.Results)
		allDeviceStates = append(allDeviceStates, states...)

		pageCount++
		s.Logger.Info().
			Int("page", pageCount).
			Int("states_in_page", len(states)).
			Int("total_states", len(allDeviceStates)).
			Int("page_limit", response.Pagination.Limit).
			Str("next_cursor", response.Pagination.NextCursor).
			Str("prev_cursor", response.Pagination.PrevCursor).
			Bool("has_next", response.Pagination.NextCursor != "").
			Msg("Fetched device states page")

		// Continue pagination if there's a next cursor
		if response.Pagination.NextCursor == "" {
			s.Logger.Info().
				Int("total_pages", pageCount).
				Int("total_device_states", len(allDeviceStates)).
				Int("last_page_size", len(states)).
				Msg("Completed fetching all device states - no more pages")
			break
		}

		cursor = response.Pagination.NextCursor
		s.Logger.Debug().
			Str("cursor_for_next_page", cursor).
			Msg("Moving to next page")
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
	s.Logger.Debug().Str("query", queryReq.Query).Str("request_body", string(reqBody)).Msg("Executing SRQL query")

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
