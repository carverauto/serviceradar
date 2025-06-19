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

package armis

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestSweepResultsQuery_GetTodaysSweepResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockHTTPClient := NewMockHTTPClient(ctrl)

	query := NewSweepResultsQuery(
		"http://localhost:8080",
		"test-api-key",
		mockHTTPClient,
	)

	// Mock response
	mockResponse := &QueryResponse{
		Results: []map[string]interface{}{
			{
				"ip":        "192.168.1.1",
				"available": true,
				"timestamp": "2025-01-30T10:00:00Z",
				"rtt":       12.5,
				"protocol":  "icmp",
			},
			{
				"ip":        "192.168.1.2",
				"available": false,
				"timestamp": "2025-01-30T10:00:01Z",
				"protocol":  "icmp",
				"error":     "timeout",
			},
		},
		Pagination: struct {
			NextCursor string `json:"next_cursor,omitempty"`
			PrevCursor string `json:"prev_cursor,omitempty"`
			Limit      int    `json:"limit"`
		}{
			Limit: 1000,
		},
	}

	responseBody, _ := json.Marshal(mockResponse)

	mockHTTPClient.EXPECT().Do(gomock.Any()).DoAndReturn(
		func(req *http.Request) (*http.Response, error) {
			// Verify request
			assert.Equal(t, "http://localhost:8080/api/query", req.URL.String())
			assert.Equal(t, "POST", req.Method)
			assert.Equal(t, "test-api-key", req.Header.Get("X-API-Key"))

			// Verify query
			var queryReq QueryRequest

			body, _ := io.ReadAll(req.Body)

			err := json.Unmarshal(body, &queryReq)
			if err != nil {
				return nil, err
			}

			assert.Equal(t, "show sweep_results where date(timestamp) = TODAY and discovery_source = \"sweep\"", queryReq.Query)
			assert.Equal(t, 1000, queryReq.Limit)

			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(bytes.NewReader(responseBody)),
			}, nil
		},
	)

	// Execute test
	results, err := query.GetTodaysSweepResults(context.Background())

	// Verify results
	require.NoError(t, err)
	assert.Len(t, results, 2)

	assert.Equal(t, "192.168.1.1", results[0].IP)
	assert.True(t, results[0].Available)
	assert.InDelta(t, 12.5, results[0].RTT, 0.0001)
	assert.Equal(t, "icmp", results[0].Protocol)

	assert.Equal(t, "192.168.1.2", results[1].IP)
	assert.False(t, results[1].Available)
	assert.Equal(t, "timeout", results[1].Error)
}

func TestSweepResultsQuery_GetSweepResultsForIPs(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockHTTPClient := NewMockHTTPClient(ctrl)

	query := NewSweepResultsQuery(
		"http://localhost:8080",
		"test-api-key",
		mockHTTPClient,
	)

	targetIPs := []string{"192.168.1.1", "192.168.1.2", "192.168.1.3"}

	// Mock response
	mockResponse := &QueryResponse{
		Results: []map[string]interface{}{
			{
				"ip":        "192.168.1.1",
				"available": true,
				"timestamp": "2025-01-30T10:00:00Z",
			},
			{
				"ip":        "192.168.1.3",
				"available": true,
				"timestamp": "2025-01-30T10:00:02Z",
			},
		},
	}

	responseBody, _ := json.Marshal(mockResponse)

	mockHTTPClient.EXPECT().Do(gomock.Any()).DoAndReturn(
		func(req *http.Request) (*http.Response, error) {
			// Verify query contains the IP list
			var queryReq QueryRequest

			body, _ := io.ReadAll(req.Body)

			err := json.Unmarshal(body, &queryReq)
			if err != nil {
				return nil, err
			}

			expectedQuery := "show sweep_results where ip IN ('192.168.1.1', '192.168.1.2', '192.168.1.3') and date(timestamp) = TODAY"
			assert.Equal(t, expectedQuery, queryReq.Query)

			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(bytes.NewReader(responseBody)),
			}, nil
		},
	)

	// Execute test
	results, err := query.GetSweepResultsForIPs(context.Background(), targetIPs)

	// Verify results
	require.NoError(t, err)
	assert.Len(t, results, 2)
	assert.Equal(t, "192.168.1.1", results[0].IP)
	assert.Equal(t, "192.168.1.3", results[1].IP)
}

func TestSweepResultsQuery_Pagination(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockHTTPClient := NewMockHTTPClient(ctrl)

	query := NewSweepResultsQuery(
		"http://localhost:8080",
		"test-api-key",
		mockHTTPClient,
	)

	// First page response
	firstPageResponse := &QueryResponse{
		Results: []map[string]interface{}{
			{"ip": "192.168.1.1", "available": true, "timestamp": "2025-01-30T10:00:00Z"},
		},
		Pagination: struct {
			NextCursor string `json:"next_cursor,omitempty"`
			PrevCursor string `json:"prev_cursor,omitempty"`
			Limit      int    `json:"limit"`
		}{
			NextCursor: "eyJpcCI6IjE5Mi4xNjguMS4xIn0=",
			Limit:      1000,
		},
	}

	// Second page response
	secondPageResponse := &QueryResponse{
		Results: []map[string]interface{}{
			{"ip": "192.168.1.2", "available": false, "timestamp": "2025-01-30T10:00:01Z"},
		},
		Pagination: struct {
			NextCursor string `json:"next_cursor,omitempty"`
			PrevCursor string `json:"prev_cursor,omitempty"`
			Limit      int    `json:"limit"`
		}{
			NextCursor: "", // No more pages
			Limit:      1000,
		},
	}

	firstPageBody, _ := json.Marshal(firstPageResponse)
	secondPageBody, _ := json.Marshal(secondPageResponse)

	// Set up expectations for two calls
	gomock.InOrder(
		mockHTTPClient.EXPECT().Do(gomock.Any()).DoAndReturn(
			func(req *http.Request) (*http.Response, error) {
				var queryReq QueryRequest

				body, _ := io.ReadAll(req.Body)

				err := json.Unmarshal(body, &queryReq)
				if err != nil {
					return nil, err
				}

				// First call should have no cursor
				assert.Empty(t, queryReq.Cursor)

				return &http.Response{
					StatusCode: http.StatusOK,
					Body:       io.NopCloser(bytes.NewReader(firstPageBody)),
				}, nil
			},
		),
		mockHTTPClient.EXPECT().Do(gomock.Any()).DoAndReturn(
			func(req *http.Request) (*http.Response, error) {
				var queryReq QueryRequest

				body, _ := io.ReadAll(req.Body)

				err := json.Unmarshal(body, &queryReq)
				if err != nil {
					return nil, err
				}

				// Second call should have the cursor from first response
				assert.Equal(t, "eyJpcCI6IjE5Mi4xNjguMS4xIn0=", queryReq.Cursor)

				return &http.Response{
					StatusCode: http.StatusOK,
					Body:       io.NopCloser(bytes.NewReader(secondPageBody)),
				}, nil
			},
		),
	)

	// Execute test
	results, err := query.GetTodaysSweepResults(context.Background())

	// Verify results from both pages
	require.NoError(t, err)
	assert.Len(t, results, 2)
	assert.Equal(t, "192.168.1.1", results[0].IP)
	assert.Equal(t, "192.168.1.2", results[1].IP)
}

func TestSweepResultsQuery_GetAvailabilityStats(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockHTTPClient := NewMockHTTPClient(ctrl)

	query := NewSweepResultsQuery(
		"http://localhost:8080",
		"test-api-key",
		mockHTTPClient,
	)

	targetIPs := []string{"192.168.1.1", "192.168.1.2"}

	// Mock response with multiple results per IP
	mockResponse := &QueryResponse{
		Results: []map[string]interface{}{
			{
				"ip":        "192.168.1.1",
				"available": false,
				"timestamp": "2025-01-30T09:00:00Z", // Older
			},
			{
				"ip":        "192.168.1.1",
				"available": true,
				"timestamp": "2025-01-30T10:00:00Z", // Newer - should be used
			},
			{
				"ip":        "192.168.1.2",
				"available": true,
				"timestamp": "2025-01-30T10:00:01Z",
			},
		},
	}

	responseBody, _ := json.Marshal(mockResponse)

	mockHTTPClient.EXPECT().Do(gomock.Any()).Return(
		&http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(bytes.NewReader(responseBody)),
		}, nil,
	)

	// Execute test
	availMap, err := query.GetAvailabilityStats(context.Background(), targetIPs)

	// Verify results
	require.NoError(t, err)
	assert.Len(t, availMap, 2)
	assert.True(t, availMap["192.168.1.1"]) // Should use the newer result
	assert.True(t, availMap["192.168.1.2"])
}

func TestArmisIntegration_PrepareArmisUpdate(t *testing.T) {
	armisInteg := &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint: "http://serviceradar.example.com",
		},
	}

	devices := []Device{
		{
			ID:        1,
			IPAddress: "192.168.1.1",
			Name:      "Device1",
		},
		{
			ID:        2,
			IPAddress: "192.168.1.2, 10.0.0.1", // Multiple IPs
			Name:      "Device2",
		},
		{
			ID:        3,
			IPAddress: "192.168.1.3",
			Name:      "Device3",
		},
	}

	sweepResults := []SweepResult{
		{
			IP:        "192.168.1.1",
			Available: true,
			Timestamp: time.Now(),
			RTT:       10.5,
		},
		{
			IP:        "192.168.1.2",
			Available: false,
			Timestamp: time.Now(),
		},
		// No result for 192.168.1.3
	}

	updates := armisInteg.PrepareArmisUpdate(context.Background(), devices, sweepResults)

	assert.Len(t, updates, 3)

	// Check device 1
	assert.Equal(t, 1, updates[0].DeviceID)
	assert.Equal(t, "192.168.1.1", updates[0].IP)
	assert.True(t, updates[0].Available)
	assert.InDelta(t, 10.5, updates[0].RTT, 0.0001)

	// Check device 2 (should use first IP)
	assert.Equal(t, 2, updates[1].DeviceID)
	assert.Equal(t, "192.168.1.2", updates[1].IP)
	assert.False(t, updates[1].Available)

	// Check device 3 (no sweep result)
	assert.Equal(t, 3, updates[2].DeviceID)
	assert.Equal(t, "192.168.1.3", updates[2].IP)
	assert.False(t, updates[2].Available)
	assert.Zero(t, updates[2].RTT)
}

func TestExtractFirstIP(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{"Single IP", "192.168.1.1", "192.168.1.1"},
		{"Multiple IPs", "192.168.1.1, 10.0.0.1, 172.16.0.1", "192.168.1.1"},
		{"IP with spaces", " 192.168.1.1 ", "192.168.1.1"},
		{"Empty string", "", ""},
		{"Multiple IPs no space", "192.168.1.1,10.0.0.1", "192.168.1.1"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractFirstIP(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestSweepResultsQuery_ErrorHandling(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	tests := []struct {
		name          string
		setupMock     func(*MockHTTPClient)
		expectedError string
	}{
		{
			name: "HTTP error",
			setupMock: func(mock *MockHTTPClient) {
				mock.EXPECT().Do(gomock.Any()).Return(nil, assert.AnError)
			},
			expectedError: "failed to execute request",
		},
		{
			name: "Non-200 status",
			setupMock: func(mock *MockHTTPClient) {
				mock.EXPECT().Do(gomock.Any()).Return(
					&http.Response{
						StatusCode: http.StatusInternalServerError,
						Body:       io.NopCloser(strings.NewReader("Internal Server Error")),
					}, nil,
				)
			},
			expectedError: "API returned status 500",
		},
		{
			name: "Query error in response",
			setupMock: func(mock *MockHTTPClient) {
				response := &QueryResponse{
					Error: "Invalid query syntax",
				}
				body, _ := json.Marshal(response)
				mock.EXPECT().Do(gomock.Any()).Return(
					&http.Response{
						StatusCode: http.StatusOK,
						Body:       io.NopCloser(bytes.NewReader(body)),
					}, nil,
				)
			},
			expectedError: "query error: Invalid query syntax",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockHTTPClient := NewMockHTTPClient(ctrl)
			tt.setupMock(mockHTTPClient)

			query := NewSweepResultsQuery(
				"http://localhost:8080",
				"test-api-key",
				mockHTTPClient,
			)

			_, err := query.GetTodaysSweepResults(context.Background())
			require.Error(t, err)
			assert.Contains(t, err.Error(), tt.expectedError)
		})
	}
}
