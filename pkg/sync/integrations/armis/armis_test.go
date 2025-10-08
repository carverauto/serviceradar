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
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	testAccessToken = "test-access-token"
)

// TestArmisIntegration_Fetch_NoUpdater tests the fetch logic when no updater is configured.
func TestArmisIntegration_Fetch_NoUpdater(t *testing.T) {
	integration, mocks := setupArmisIntegration(t)
	// Explicitly disable the updater and querier for this test case
	integration.Updater = nil
	integration.SweepQuerier = nil

	expectedDevices := getExpectedDevices()
	firstPageResp := getFirstPageResponse(expectedDevices)
	expectedSweepConfig := &models.SweepConfig{
		Networks: []string{"192.168.1.1/32", "192.168.1.2/32"},
		DeviceTargets: []models.DeviceTarget{
			{
				Network:    "192.168.1.1/32",
				SweepModes: []models.SweepMode{},
				QueryLabel: "test",
				Source:     "armis",
				Metadata: map[string]string{
					"armis_device_id":  "1",
					"integration_id":   "1",
					"integration_type": "armis",
					"query_label":      "test",
				},
			},
			{
				Network:    "192.168.1.2/32",
				SweepModes: []models.SweepMode{},
				QueryLabel: "test",
				Source:     "armis",
				Metadata: map[string]string{
					"armis_device_id":  "2",
					"integration_id":   "2",
					"integration_type": "armis",
					"query_label":      "test",
				},
			},
		},
	}

	setupArmisMocks(t, mocks, firstPageResp, expectedSweepConfig)

	result, events, err := integration.Fetch(context.Background())
	verifyArmisResults(t, result, events, err, expectedDevices)

	// Ensure that the enrichment data was not added
	_, exists := result["_sweep_results"]
	assert.False(t, exists)
}

// TestArmisIntegration_Fetch_WithUpdaterAndCorrelation tests the discovery workflow (Fetch) and
// reconciliation workflow (Reconcile) separately.
func TestArmisIntegration_Fetch_WithUpdaterAndCorrelation(t *testing.T) {
	// 1. Setup
	integration, mocks := setupArmisIntegration(t)
	expectedDevices := getExpectedDevices()
	firstPageResp := getFirstPageResponse(expectedDevices)

	// Mock device states, one for each device IP
	mockDeviceStates := []DeviceState{
		{IP: "192.168.1.1", IsAvailable: true, Metadata: map[string]interface{}{"armis_device_id": "1"}},
		{IP: "192.168.1.2", IsAvailable: false, Metadata: map[string]interface{}{"armis_device_id": "2"}},
	}

	// 2. Test Fetch (Discovery) - should NOT perform reconciliation
	testAccessToken := testAccessToken
	expectedQuery := "in:devices orderBy=id boundaries:\"Corporate\""

	// Expectations for the initial device fetch only
	mocks.TokenProvider.EXPECT().GetAccessToken(gomock.Any()).Return(testAccessToken, nil)
	mocks.DeviceFetcher.EXPECT().FetchDevicesPage(gomock.Any(), testAccessToken, expectedQuery, 0, 100).Return(firstPageResp, nil)
	mocks.KVWriter.EXPECT().WriteSweepConfig(gomock.Any(), gomock.Any()).Return(nil)

	// 3. Execute Fetch (Discovery only)
	result, events, err := integration.Fetch(context.Background())

	// 4. Assert Fetch results (Discovery only)
	require.NoError(t, err)
	require.NotNil(t, result)

	// Verify devices and sweep results
	verifyArmisResults(t, result, events, err, expectedDevices)

	// 5. Test Reconcile (Updates) - should perform correlation and updates
	// Expectations for the reconciliation logic
	mocks.SweepQuerier.EXPECT().GetDeviceStatesBySource(gomock.Any(), "armis").Return(mockDeviceStates, nil)
	// Reconcile no longer fetches devices from Armis - it just uses what's in the database
	mocks.Updater.EXPECT().UpdateDeviceStatus(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []ArmisDeviceStatus) error {
			// Verify the content of the updates being sent to Armis
			require.Len(t, updates, 2)

			// Device 1 had a sweep result and was available
			assert.Equal(t, 1, updates[0].DeviceID)
			assert.Equal(t, "192.168.1.1", updates[0].IP)
			// We're updating a tag in Armis to mark the device as compliant if we CANT reach it
			// otherwise, we mark it as available
			assert.False(t, updates[0].Available)

			// Device 2 had a sweep result and was not available
			assert.Equal(t, 2, updates[1].DeviceID)
			assert.Equal(t, "192.168.1.2", updates[1].IP)
			// Due to the Armis integration logic, we expect this to be marked as available
			assert.True(t, updates[1].Available)

			return nil
		}).Return(nil)

	// 6. Execute Reconcile
	err = integration.Reconcile(context.Background())
	require.NoError(t, err)
}

func setupArmisIntegration(t *testing.T) (*ArmisIntegration, *armisMocks) {
	t.Helper()
	ctrl := gomock.NewController(t)

	// Ensure mock controller is finished even if test panics
	t.Cleanup(func() {
		ctrl.Finish()
	})

	mocks := &armisMocks{
		TokenProvider: NewMockTokenProvider(ctrl),
		DeviceFetcher: NewMockDeviceFetcher(ctrl),
		KVWriter:      NewMockKVWriter(ctrl),
		SweepQuerier:  NewMockSRQLQuerier(ctrl),
		Updater:       NewMockArmisUpdater(ctrl),
	}

	return &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint:  "https://armis.example.com",
			Prefix:    "armis/",
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
			Credentials: map[string]string{
				"secret_key": "test-secret-key",
			},
			Queries: []models.QueryConfig{
				{Label: "test", Query: "in:devices orderBy=id boundaries:\"Corporate\""},
			},
		},
		PageSize:      100,
		TokenProvider: mocks.TokenProvider,
		DeviceFetcher: mocks.DeviceFetcher,
		KVWriter:      mocks.KVWriter,
		SweepQuerier:  mocks.SweepQuerier,
		Updater:       mocks.Updater,
		Logger:        logger.NewTestLogger(),
	}, mocks
}

type armisMocks struct {
	TokenProvider *MockTokenProvider
	DeviceFetcher *MockDeviceFetcher
	KVWriter      *MockKVWriter
	SweepQuerier  *MockSRQLQuerier
	Updater       *MockArmisUpdater
}

func getExpectedDevices() []Device {
	return []Device{
		{
			ID:         1,
			IPAddress:  "192.168.1.1",
			MacAddress: "00:11:22:33:44:55",
			Name:       "Test Device 1",
			Type:       "Computer",
			RiskLevel:  10,
			Boundaries: "Corporate",
		},
		{
			ID:         2,
			IPAddress:  "192.168.1.2, 10.0.0.1",
			MacAddress: "AA:BB:CC:DD:EE:FF",
			Name:       "Test Device 2",
			Type:       "Mobile Phone",
			RiskLevel:  20,
			Boundaries: "Corporate",
		},
	}
}

func getFirstPageResponse(devices []Device) *SearchResponse {
	return &SearchResponse{
		Data: struct {
			Count   int         `json:"count"`
			Next    int         `json:"next"`
			Prev    interface{} `json:"prev"`
			Results []Device    `json:"results"`
			Total   int         `json:"total"`
		}{
			Count:   2,
			Next:    0,
			Prev:    nil,
			Results: devices,
			Total:   2,
		},
		Success: true,
	}
}

func setupArmisMocks(t *testing.T, mocks *armisMocks, resp *SearchResponse, _ *models.SweepConfig) {
	t.Helper()

	testAccessToken := testAccessToken
	expectedQuery := "in:devices orderBy=id boundaries:\"Corporate\""

	mocks.TokenProvider.EXPECT().GetAccessToken(gomock.Any()).Return(testAccessToken, nil)
	mocks.DeviceFetcher.EXPECT().FetchDevicesPage(gomock.Any(), testAccessToken, expectedQuery, 0, 100).Return(resp, nil)
	mocks.KVWriter.EXPECT().WriteSweepConfig(gomock.Any(), gomock.Any()).Return(nil)
}

func verifyArmisResults(t *testing.T, result map[string][]byte, events []*models.DeviceUpdate, err error, expectedDevices []Device) {
	t.Helper()

	require.NoError(t, err)
	require.NotNil(t, result)

	expectedLen := len(expectedDevices)

	for _, ed := range expectedDevices {
		ip := extractFirstIP(ed.IPAddress)
		if ip != "" {
			expectedLen++
		}
	}

	if _, ok := result["_sweep_results"]; ok {
		expectedLen++
	}

	assert.Len(t, result, expectedLen)

	for i := range expectedDevices {
		expected := &expectedDevices[i]

		ip := extractFirstIP(expected.IPAddress)
		if ip == "" {
			continue
		}

		key := fmt.Sprintf("test-agent/%s", ip)
		deviceData, exists := result[key]

		require.True(t, exists, "device with key %s should exist", key)

		var device models.SweepResult

		err = json.Unmarshal(deviceData, &device)
		require.NoError(t, err)

		assert.Equal(t, ip, device.IP)
		assert.Equal(t, "test-poller", device.PollerID)
	}

	assert.Len(t, events, len(expectedDevices))

	for i, ev := range events {
		exp := expectedDevices[i]

		require.Equal(t, extractFirstIP(exp.IPAddress), ev.IP)
		require.Equal(t, "test-poller", ev.PollerID)
	}
}

func TestArmisIntegration_FetchWithMultiplePages(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint:  "https://armis.example.com",
			Prefix:    "armis/",
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
			Credentials: map[string]string{
				"secret_key": "test-secret-key",
			},
			Queries: []models.QueryConfig{
				{Label: "test", Query: "in:devices orderBy=id"},
			},
		},
		PageSize:      50,
		TokenProvider: NewMockTokenProvider(ctrl),
		DeviceFetcher: NewMockDeviceFetcher(ctrl),
		KVWriter:      NewMockKVWriter(ctrl),
		// Explicitly nil for this test's scope
		Updater:      nil,
		SweepQuerier: nil,
		Logger:       logger.NewTestLogger(),
	}

	testAccessToken := testAccessToken
	firstPageDevices := []Device{{ID: 1, IPAddress: "192.168.1.1", Name: "Device 1"}, {ID: 2, IPAddress: "192.168.1.2", Name: "Device 2"}}
	secondPageDevices := []Device{{ID: 3, IPAddress: "192.168.1.3", Name: "Device 3"}, {ID: 4, IPAddress: "192.168.1.4", Name: "Device 4"}}
	firstPageResp := &SearchResponse{Data: struct {
		Count   int         `json:"count"`
		Next    int         `json:"next"`
		Prev    interface{} `json:"prev"`
		Results []Device    `json:"results"`
		Total   int         `json:"total"`
	}{Count: 2, Next: 2, Prev: nil, Results: firstPageDevices, Total: 4}, Success: true}
	secondPageResp := &SearchResponse{Data: struct {
		Count   int         `json:"count"`
		Next    int         `json:"next"`
		Prev    interface{} `json:"prev"`
		Results []Device    `json:"results"`
		Total   int         `json:"total"`
	}{Count: 2, Next: 0, Prev: 0, Results: secondPageDevices, Total: 4}, Success: true}
	expectedQuery := "in:devices orderBy=id"

	integration.TokenProvider.(*MockTokenProvider).
		EXPECT().GetAccessToken(gomock.Any()).Return(testAccessToken, nil)
	integration.DeviceFetcher.(*MockDeviceFetcher).
		EXPECT().FetchDevicesPage(gomock.Any(), testAccessToken, expectedQuery, 0, 50).Return(firstPageResp, nil)
	integration.DeviceFetcher.(*MockDeviceFetcher).
		EXPECT().FetchDevicesPage(gomock.Any(), testAccessToken, expectedQuery, 2, 50).Return(secondPageResp, nil)
	integration.KVWriter.(*MockKVWriter).
		EXPECT().WriteSweepConfig(gomock.Any(), gomock.Any()).Return(nil)

	result, _, err := integration.Fetch(context.Background())

	require.NoError(t, err)
	require.NotNil(t, result)

	assert.Len(t, result, 8)

	for i := 1; i <= 4; i++ {
		key := fmt.Sprintf("test-agent/192.168.1.%d", i)
		_, exists := result[key]
		assert.True(t, exists, "Device with key %s should exist in results", key)
	}
}

func TestArmisIntegration_FetchErrorHandling(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint: "https://armis.example.com",
			Prefix:   "armis/",
			Credentials: map[string]string{
				"secret_key": "test-secret-key",
			},
			Queries: []models.QueryConfig{
				{Label: "test", Query: "in:devices orderBy=id"},
			},
		},
		PageSize:      100,
		TokenProvider: NewMockTokenProvider(ctrl),
		DeviceFetcher: NewMockDeviceFetcher(ctrl),
		KVWriter:      NewMockKVWriter(ctrl),
		// Explicitly nil for this test's scope
		Updater:      nil,
		SweepQuerier: nil,
		Logger:       logger.NewTestLogger(),
	}

	testCases := []struct {
		name          string
		setupMocks    func(*ArmisIntegration)
		expectedError string
	}{
		{
			name: "token provider error",
			setupMocks: func(i *ArmisIntegration) {
				i.TokenProvider.(*MockTokenProvider).EXPECT().GetAccessToken(gomock.Any()).Return("", errAuthFailed)
			},
			expectedError: "failed to get access token: authentication failed",
		},
		{
			name: "device fetcher error",
			setupMocks: func(i *ArmisIntegration) {
				i.TokenProvider.(*MockTokenProvider).
					EXPECT().GetAccessToken(gomock.Any()).Return("test-token", nil)
				i.DeviceFetcher.(*MockDeviceFetcher).
					EXPECT().FetchDevicesPage(
					gomock.Any(), "test-token", "in:devices orderBy=id", 0, 100).Return(nil, errNetworkError)
			},
			expectedError: "network error",
		},
		{
			name: "kv writer error is logged but doesn't fail fetch",
			setupMocks: func(i *ArmisIntegration) {
				i.TokenProvider.(*MockTokenProvider).EXPECT().GetAccessToken(gomock.Any()).Return("test-token", nil)
				firstPageResp := &SearchResponse{Data: struct {
					Count   int         `json:"count"`
					Next    int         `json:"next"`
					Prev    interface{} `json:"prev"`
					Results []Device    `json:"results"`
					Total   int         `json:"total"`
				}{Count: 1, Next: 0,
					Results: []Device{{ID: 1, IPAddress: "192.168.1.1", Name: "Device 1"}}, Total: 1}, Success: true}
				i.DeviceFetcher.(*MockDeviceFetcher).
					EXPECT().FetchDevicesPage(gomock.Any(),
					"test-token", "in:devices orderBy=id", 0, 100).Return(firstPageResp, nil)
				i.KVWriter.(*MockKVWriter).
					EXPECT().WriteSweepConfig(gomock.Any(), gomock.Any()).Return(errKVWriteError)
			},
			expectedError: "",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			tc.setupMocks(integration)

			result, _, err := integration.Fetch(context.Background())
			if tc.expectedError != "" {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tc.expectedError)
				assert.Nil(t, result)
			} else {
				require.NoError(t, err)
				require.NotNil(t, result)
			}
		})
	}
}

func TestArmisIntegration_FetchNoQueries(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockTokenProvider := NewMockTokenProvider(ctrl)
	// Add expectation for GetAccessToken which is called before checking for empty queries
	mockTokenProvider.EXPECT().GetAccessToken(gomock.Any()).Return("test-token", nil)

	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint: "https://armis.example.com",
			Prefix:   "armis/",
			Credentials: map[string]string{
				"secret_key": "test-secret-key",
			},
			Queries: []models.QueryConfig{}, // Empty queries
		},
		PageSize:      100,
		TokenProvider: mockTokenProvider,
		DeviceFetcher: NewMockDeviceFetcher(ctrl),
		KVWriter:      NewMockKVWriter(ctrl),
	}

	result, _, err := integration.Fetch(context.Background())

	assert.Nil(t, result)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no queries configured")
}

// TestArmisIntegration_FetchMultipleQueries tests that multiple queries are accumulated in memory
// and all devices are included in the final sweep.json, preventing the overwriting issue.
func TestArmisIntegration_FetchMultipleQueries(t *testing.T) {
	integration, mocks := setupArmisIntegration(t)

	// Configure multiple queries
	integration.Config.Queries = []models.QueryConfig{
		{Label: "corporate_devices", Query: "in:devices boundaries:\"Corporate\""},
		{Label: "guest_devices", Query: "in:devices boundaries:\"Guest\""},
	}

	// Mock devices for first query (corporate)
	corporateDevices := []Device{
		{ID: 1, Name: "corporate-laptop-1", IPAddress: "192.168.1.100", MacAddress: "00:11:22:33:44:55"},
		{ID: 2, Name: "corporate-laptop-2", IPAddress: "192.168.1.101", MacAddress: "00:11:22:33:44:56"},
	}

	// Mock devices for second query (guest)
	guestDevices := []Device{
		{ID: 3, Name: "guest-phone-1", IPAddress: "192.168.2.100", MacAddress: "00:11:22:33:44:57"},
		{ID: 4, Name: "guest-tablet-1", IPAddress: "192.168.2.101", MacAddress: "00:11:22:33:44:58"},
	}

	testAccessToken := testAccessToken

	// Set up expectations for token provider
	mocks.TokenProvider.EXPECT().GetAccessToken(gomock.Any()).Return(testAccessToken, nil)

	// Set up expectations for first query (corporate)
	corporateResp := &SearchResponse{
		Success: true,
		Data: struct {
			Count   int         `json:"count"`
			Next    int         `json:"next"`
			Prev    interface{} `json:"prev"`
			Results []Device    `json:"results"`
			Total   int         `json:"total"`
		}{
			Count:   len(corporateDevices),
			Next:    0, // No next page
			Prev:    nil,
			Results: corporateDevices,
			Total:   len(corporateDevices),
		},
	}
	mocks.DeviceFetcher.EXPECT().
		FetchDevicesPage(gomock.Any(), testAccessToken, "in:devices boundaries:\"Corporate\"", 0, 100).
		Return(corporateResp, nil)

	// Set up expectations for second query (guest)
	guestResp := &SearchResponse{
		Success: true,
		Data: struct {
			Count   int         `json:"count"`
			Next    int         `json:"next"`
			Prev    interface{} `json:"prev"`
			Results []Device    `json:"results"`
			Total   int         `json:"total"`
		}{
			Count:   len(guestDevices),
			Next:    0, // No next page
			Prev:    nil,
			Results: guestDevices,
			Total:   len(guestDevices),
		},
	}
	mocks.DeviceFetcher.EXPECT().
		FetchDevicesPage(gomock.Any(), testAccessToken, "in:devices boundaries:\"Guest\"", 0, 100).
		Return(guestResp, nil)

	// The KVWriter should be called ONCE with a sweep config containing ALL devices from BOTH queries

	mocks.KVWriter.EXPECT().
		WriteSweepConfig(gomock.Any(), gomock.Any()).
		Return(nil)

	// Execute the fetch
	result, events, err := integration.Fetch(context.Background())

	// Verify no errors
	require.NoError(t, err)
	require.NotNil(t, result)

	// Verify that we got devices from BOTH queries
	assert.Len(t, events, 4, "Should have 4 device events from both queries combined")

	// Verify device labels are correctly assigned
	corporateEvents := 0
	guestEvents := 0

	for _, event := range events {
		queryLabel, exists := event.Metadata["query_label"]
		require.True(t, exists, "Each device should have a query_label")

		switch queryLabel {
		case "corporate_devices":
			corporateEvents++
		case "guest_devices":
			guestEvents++
		default:
			t.Errorf("Unexpected query_label: %s", queryLabel)
		}
	}

	assert.Equal(t, 2, corporateEvents, "Should have 2 events from corporate query")
	assert.Equal(t, 2, guestEvents, "Should have 2 events from guest query")

	// Verify KV data contains entries for all devices
	assert.Len(t, result, 8, "Should have 8 KV entries: 4 device data + 4 agent/IP entries")

	t.Log("Successfully verified that multiple queries are accumulated in memory and written as single sweep config")
}

func createSuccessResponse(t *testing.T) *http.Response {
	t.Helper()

	respData := createExpectedResponse(t)
	respJSON, err := json.Marshal(respData)
	require.NoError(t, err)

	// Return a response with a NopCloser body that doesn't need explicit closing
	return &http.Response{
		StatusCode: http.StatusOK,
		Body:       io.NopCloser(bytes.NewReader(respJSON)),
	}
}

func TestDefaultArmisIntegration_FetchDevicesPage(t *testing.T) {
	testCases := []struct {
		name           string
		accessToken    string
		query          string
		from           int
		length         int
		mockError      error
		expectedResult *SearchResponse
		expectedError  string
	}{
		{
			name:           "successful fetch",
			accessToken:    "test-token",
			query:          "in:devices",
			from:           0,
			length:         10,
			expectedResult: createExpectedResponse(t),
			expectedError:  "",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			// Create the response inside the test loop
			mockResponse := createSuccessResponse(t)
			if mockResponse != nil {
				defer func() {
					if err := mockResponse.Body.Close(); err != nil {
						t.Logf("Failed to close response body: %v", err)
					}
				}()
			}

			impl := setupDefaultArmisIntegration(t, mockResponse, tc.mockError)

			result, err := impl.FetchDevicesPage(context.Background(), tc.accessToken, tc.query, tc.from, tc.length)

			if tc.expectedError != "" {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tc.expectedError)
				assert.Nil(t, result)
			} else {
				require.NoError(t, err)
				assert.Equal(t, tc.expectedResult, result)
			}
		})
	}
}

func createExpectedResponse(t *testing.T) *SearchResponse {
	t.Helper()

	return &SearchResponse{Data: struct {
		Count   int         `json:"count"`
		Next    int         `json:"next"`
		Prev    interface{} `json:"prev"`
		Results []Device    `json:"results"`
		Total   int         `json:"total"`
	}{Count: 2, Next: 0, Prev: nil,
		Results: []Device{
			{ID: 1, IPAddress: "192.168.1.1", Name: "Device 1"},
			{ID: 2, IPAddress: "192.168.1.2", Name: "Device 2"},
		}, Total: 2}, Success: true}
}

func setupDefaultArmisIntegration(t *testing.T, resp *http.Response, mockErr error) *DefaultArmisIntegration {
	t.Helper()

	ctrl := gomock.NewController(t)

	mockHTTPClient := NewMockHTTPClient(ctrl)
	mockHTTPClient.EXPECT().Do(gomock.Any()).Return(resp, mockErr)

	return &DefaultArmisIntegration{
		Config:     &models.SourceConfig{Endpoint: "https://armis.example.com"},
		HTTPClient: mockHTTPClient,
		Logger:     logger.NewTestLogger(),
	}
}

func TestDefaultArmisIntegration_GetAccessToken(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	defaultImpl := &DefaultArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint: "https://armis.example.com",
			Credentials: map[string]string{
				"secret_key": "test-secret-key",
			},
		},
		HTTPClient: NewMockHTTPClient(ctrl),
		Logger:     logger.NewTestLogger(),
	}

	testCases := []struct {
		name          string
		setupMock     func(*MockHTTPClientMockRecorder)
		expectedToken string
		expectedError string
	}{
		{
			name: "successful token request",
			setupMock: func(mock *MockHTTPClientMockRecorder) {
				mock.Do(gomock.Any()).Return(&http.Response{
					StatusCode: http.StatusOK,
					Body: io.NopCloser(
						strings.NewReader(
							`{"data": {"access_token": "test-access-token", "expiration_utc": "2023-10-11T09:49:00.818613+00:00"}, "success": true}`)),
				}, nil)
			},
			expectedToken: testAccessToken,
			expectedError: "",
		},
		{
			name: "HTTP client error",
			setupMock: func(mock *MockHTTPClientMockRecorder) {
				mock.Do(gomock.Any()).Return(nil, errConnectionRefused)
			},
			expectedToken: "",
			expectedError: "connection refused",
		},
		{
			name: "API error response",
			setupMock: func(mock *MockHTTPClientMockRecorder) {
				mock.Do(gomock.Any()).Return(&http.Response{
					StatusCode: http.StatusBadRequest,
					Body:       io.NopCloser(strings.NewReader(`{"message": "Invalid secret key", "success": false}`)),
				}, nil)
			},
			expectedToken: "",
			expectedError: "unexpected status code: 400",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			tc.setupMock(defaultImpl.HTTPClient.(*MockHTTPClient).EXPECT())

			token, err := defaultImpl.GetAccessToken(context.Background())
			if tc.expectedError != "" {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tc.expectedError)
				assert.Empty(t, token)
			} else {
				require.NoError(t, err)
				assert.Equal(t, tc.expectedToken, token)
			}
		})
	}
}

type mockKVClient struct {
	ctrl     *gomock.Controller
	recorder *mockKVClientRecorder
}

type mockKVClientRecorder struct {
	mock *mockKVClient
}

func newMockKVClient(ctrl *gomock.Controller) *mockKVClient {
	mock := &mockKVClient{ctrl: ctrl}
	mock.recorder = &mockKVClientRecorder{mock}

	return mock
}

func (m *mockKVClient) EXPECT() *mockKVClientRecorder {
	return m.recorder
}

func (m *mockKVClient) Put(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error) {
	m.ctrl.T.Helper()

	varargs := []interface{}{ctx, in}

	for _, a := range opts {
		varargs = append(varargs, a)
	}

	ret := m.ctrl.Call(m, "Put", varargs...)

	ret0, _ := ret[0].(*proto.PutResponse)
	ret1, _ := ret[1].(error)

	return ret0, ret1
}

func (m *mockKVClient) PutIfAbsent(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error) {
	m.ctrl.T.Helper()

	varargs := []interface{}{ctx, in}

	for _, a := range opts {
		varargs = append(varargs, a)
	}

	ret := m.ctrl.Call(m, "PutIfAbsent", varargs...)

	ret0, _ := ret[0].(*proto.PutResponse)
	ret1, _ := ret[1].(error)

	return ret0, ret1
}

func (m *mockKVClient) PutMany(ctx context.Context, in *proto.PutManyRequest, opts ...grpc.CallOption) (*proto.PutManyResponse, error) {
	m.ctrl.T.Helper()

	varargs := []interface{}{ctx, in}

	for _, a := range opts {
		varargs = append(varargs, a)
	}

	ret := m.ctrl.Call(m, "PutMany", varargs...)
	ret0, _ := ret[0].(*proto.PutManyResponse)
	ret1, _ := ret[1].(error)

	return ret0, ret1
}

func (m *mockKVClient) Update(ctx context.Context, in *proto.UpdateRequest, opts ...grpc.CallOption) (*proto.UpdateResponse, error) {
	m.ctrl.T.Helper()

	varargs := []interface{}{ctx, in}

	for _, a := range opts {
		varargs = append(varargs, a)
	}

	ret := m.ctrl.Call(m, "Update", varargs...)
	ret0, _ := ret[0].(*proto.UpdateResponse)
	ret1, _ := ret[1].(error)

	return ret0, ret1
}

func (mr *mockKVClientRecorder) PutMany(ctx, in interface{}, opts ...interface{}) *gomock.Call {
	mr.mock.ctrl.T.Helper()

	varargs := append([]interface{}{ctx, in}, opts...)

	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "PutMany", reflect.TypeOf((*mockKVClient)(nil).PutMany), varargs...)
}

func (mr *mockKVClientRecorder) Put(ctx, in interface{}, opts ...interface{}) *gomock.Call {
	mr.mock.ctrl.T.Helper()

	varargs := append([]interface{}{ctx, in}, opts...)

	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Put", reflect.TypeOf((*mockKVClient)(nil).Put), varargs...)
}

func (mr *mockKVClientRecorder) Update(ctx, in interface{}, opts ...interface{}) *gomock.Call {
	mr.mock.ctrl.T.Helper()

	varargs := append([]interface{}{ctx, in}, opts...)

	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Update", reflect.TypeOf((*mockKVClient)(nil).Update), varargs...)
}

func (mr *mockKVClientRecorder) PutIfAbsent(ctx, in interface{}, opts ...interface{}) *gomock.Call {
	mr.mock.ctrl.T.Helper()

	varargs := append([]interface{}{ctx, in}, opts...)

	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "PutIfAbsent", reflect.TypeOf((*mockKVClient)(nil).PutIfAbsent), varargs...)
}

func (*mockKVClient) Get(_ context.Context, _ *proto.GetRequest, _ ...grpc.CallOption) (*proto.GetResponse, error) {
	return nil, errNotImplemented
}

func (*mockKVClient) BatchGet(_ context.Context, _ *proto.BatchGetRequest, _ ...grpc.CallOption) (*proto.BatchGetResponse, error) {
	return nil, errNotImplemented
}

func (*mockKVClient) Delete(_ context.Context, _ *proto.DeleteRequest, _ ...grpc.CallOption) (*proto.DeleteResponse, error) {
	return nil, errNotImplemented
}

func (*mockKVClient) Watch(_ context.Context, _ *proto.WatchRequest, _ ...grpc.CallOption) (proto.KVService_WatchClient, error) {
	return nil, errNotImplemented
}

func (*mockKVClient) Info(_ context.Context, _ *proto.InfoRequest, _ ...grpc.CallOption) (*proto.InfoResponse, error) {
	return &proto.InfoResponse{Domain: "test", Bucket: "test"}, nil
}

func TestDefaultKVWriter_WriteSweepConfig(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := newMockKVClient(ctrl)
	t.Logf("MockKVClient created: %v", mockKV)

	kvWriter := &DefaultKVWriter{
		KVClient:   mockKV,
		ServerName: "test-server",
		AgentID:    "test-server",
		Logger:     logger.NewTestLogger(),
	}

	testSweepConfig := &models.SweepConfig{
		Networks: []string{"192.168.1.1/32", "192.168.1.2/32"},
	}

	testCases := []struct {
		name          string
		setupMock     func(*mockKVClientRecorder)
		expectedError string
	}{
		{
			name: "successful write",
			setupMock: func(mock *mockKVClientRecorder) {
				t.Log("Setting up mock expectation for PutMany")
				mock.PutMany(gomock.Any(), gomock.Any(), gomock.Any()).
					DoAndReturn(func(_ context.Context, req *proto.PutManyRequest, _ ...grpc.CallOption) (*proto.PutManyResponse, error) {
						assert.Len(t, req.Entries, 1)
						assert.Equal(t, "agents/test-server/checkers/sweep/sweep.json", req.Entries[0].Key)

						var config models.SweepConfig
						err := json.Unmarshal(req.Entries[0].Value, &config)
						require.NoError(t, err)
						assert.Equal(t, testSweepConfig.Networks, config.Networks)

						return &proto.PutManyResponse{}, nil
					})
			},
			expectedError: "",
		},
		{
			name: "KV client error",
			setupMock: func(mock *mockKVClientRecorder) {
				t.Log("Setting up mock expectation for PutMany with error")
				mock.PutMany(gomock.Any(), gomock.Any(), gomock.Any()).Return(nil, errNetworkError)
			},
			expectedError: "failed to write sweep config",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			t.Log("Starting test case setup")

			tc.setupMock(mockKV.EXPECT())

			t.Log("Mock expectation set")
			t.Log("Calling WriteSweepConfig")

			err := kvWriter.WriteSweepConfig(context.Background(), testSweepConfig)

			t.Log("WriteSweepConfig returned")

			if tc.expectedError != "" {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tc.expectedError)
			} else {
				require.NoError(t, err)
			}
		})
	}
}

func TestDefaultArmisUpdater_UpdateDeviceStatus(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockHTTP := NewMockHTTPClient(ctrl)
	mockToken := NewMockTokenProvider(ctrl)

	updater := &DefaultArmisUpdater{
		Config:        &models.SourceConfig{Endpoint: "https://armis.example.com"},
		HTTPClient:    mockHTTP,
		TokenProvider: mockToken,
		Logger:        logger.NewTestLogger(),
	}

	updates := []ArmisDeviceStatus{
		{
			DeviceID:    1,
			Available:   true,
			LastChecked: time.Date(2025, 1, 1, 12, 0, 0, 0, time.UTC),
			RTT:         10.5,
		},
		{
			DeviceID:    2,
			Available:   false,
			LastChecked: time.Date(2025, 1, 1, 12, 5, 0, 0, time.UTC),
		},
	}

	mockToken.EXPECT().GetAccessToken(gomock.Any()).Return("token", nil)
	mockHTTP.EXPECT().Do(gomock.Any()).DoAndReturn(
		func(req *http.Request) (*http.Response, error) {
			require.Equal(t, http.MethodPost, req.Method)
			require.Equal(t, "https://armis.example.com/api/v1/devices/custom-properties/_bulk/", req.URL.String())
			require.Equal(t, "token", req.Header.Get("Authorization"))

			body, err := io.ReadAll(req.Body)
			require.NoError(t, err)

			var payload []map[string]map[string]interface{}

			err = json.Unmarshal(body, &payload)
			require.NoError(t, err)

			// Expect one operation per device
			require.Len(t, payload, 2, "payload length")

			return &http.Response{StatusCode: http.StatusMultiStatus, Body: io.NopCloser(strings.NewReader(`[{"result":{},"status":202}]`))}, nil
		},
	)

	err := updater.UpdateDeviceStatus(context.Background(), updates)
	require.NoError(t, err)
}

// TestProcessDevices verifies that Armis devices are converted into KV entries and IP list
func TestProcessDevices(t *testing.T) {
	integ := &ArmisIntegration{
		Config: &models.SourceConfig{AgentID: "test-agent", PollerID: "poller", Partition: "part"},
		Logger: logger.NewTestLogger(),
	}

	devices := []Device{
		{ID: 1, IPAddress: "192.168.1.1", MacAddress: "aa:bb", Name: "dev1", Tags: []string{"t1"}},
		{ID: 2, IPAddress: "192.168.1.2,10.0.0.1", MacAddress: "cc:dd", Name: "dev2"},
	}

	deviceLabels := map[int]string{
		1: "test_query_1",
		2: "test_query_2",
	}

	deviceQueries := map[int]models.QueryConfig{
		1: {Label: "test_query_1", SweepModes: []models.SweepMode{models.ModeTCP}},
		2: {Label: "test_query_2", SweepModes: []models.SweepMode{models.ModeICMP}},
	}

	data, ips, events, deviceTargets := integ.processDevices(context.Background(), devices, deviceLabels, deviceQueries)

	require.Len(t, data, 4) // two device keys and two sweep device entries
	assert.ElementsMatch(t, []string{"test-agent/192.168.1.1", "test-agent/192.168.1.2"}, keysWithPrefix(data, "test-agent/"))
	assert.Empty(t, ips) // ips array is no longer populated since we use device_targets instead

	// Verify events were created correctly
	require.Len(t, events, 2, "should have one event per device")

	// Check first event
	assert.Equal(t, "test-agent", events[0].AgentID)
	assert.Equal(t, "poller", events[0].PollerID)
	assert.Equal(t, "192.168.1.1", events[0].IP)
	assert.Equal(t, "part:192.168.1.1", events[0].DeviceID)
	assert.Equal(t, "part", events[0].Partition)
	assert.Equal(t, models.DiscoverySourceArmis, events[0].Source)
	assert.False(t, events[0].IsAvailable) // Defaults to false in discovery, actual availability comes from sweep
	assert.NotNil(t, events[0].Hostname)
	assert.Equal(t, "dev1", *events[0].Hostname)
	assert.NotNil(t, events[0].MAC)
	assert.Equal(t, "aa:bb", *events[0].MAC)
	assert.NotNil(t, events[0].Metadata)
	assert.Equal(t, "armis", events[0].Metadata["integration_type"])
	assert.Equal(t, "1", events[0].Metadata["integration_id"])
	assert.Equal(t, "1", events[0].Metadata["armis_device_id"])
	assert.Equal(t, "test_query_1", events[0].Metadata["query_label"])

	// Check second event
	assert.Equal(t, "test-agent", events[1].AgentID)
	assert.Equal(t, "poller", events[1].PollerID)
	assert.Equal(t, "192.168.1.2", events[1].IP)
	assert.Equal(t, "part:192.168.1.2", events[1].DeviceID)
	assert.Equal(t, "part", events[1].Partition)
	assert.Equal(t, models.DiscoverySourceArmis, events[1].Source)
	assert.False(t, events[1].IsAvailable) // Defaults to false in discovery, actual availability comes from sweep
	assert.NotNil(t, events[1].Hostname)
	assert.Equal(t, "dev2", *events[1].Hostname)
	assert.NotNil(t, events[1].MAC)
	assert.Equal(t, "cc:dd", *events[1].MAC)
	assert.NotNil(t, events[1].Metadata)
	assert.Equal(t, "armis", events[1].Metadata["integration_type"])
	assert.Equal(t, "2", events[1].Metadata["integration_id"])
	assert.Equal(t, "2", events[1].Metadata["armis_device_id"])
	assert.Equal(t, "test_query_2", events[1].Metadata["query_label"])

	// Verify device targets were created correctly
	require.Len(t, deviceTargets, 2)
	// Find device targets by network
	var target1, target2 *models.DeviceTarget

	for i := range deviceTargets {
		target := &deviceTargets[i]
		switch target.Network {
		case "192.168.1.1/32":
			target1 = target
		case "192.168.1.2/32":
			target2 = target
		}
	}
	// Verify device target 1 (TCP)
	require.NotNil(t, target1)
	assert.Equal(t, []models.SweepMode{models.ModeTCP}, target1.SweepModes)
	assert.Equal(t, "test_query_1", target1.QueryLabel)
	assert.Equal(t, "armis", target1.Source)
	assert.Equal(t, "1", target1.Metadata["armis_device_id"])
	// Verify device target 2 (ICMP)
	require.NotNil(t, target2)
	assert.Equal(t, []models.SweepMode{models.ModeICMP}, target2.SweepModes)
	assert.Equal(t, "test_query_2", target2.QueryLabel)
	assert.Equal(t, "armis", target2.Source)
	assert.Equal(t, "2", target2.Metadata["armis_device_id"])

	raw := data["1"]

	var withMeta DeviceWithMetadata

	require.NoError(t, json.Unmarshal(raw, &withMeta))
	assert.Equal(t, 1, withMeta.ID)
	assert.Equal(t, "t1", withMeta.Metadata["tag"])
}

type fakeKVClient struct {
	getFn      func(ctx context.Context, in *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error)
	batchGetFn func(ctx context.Context, in *proto.BatchGetRequest, opts ...grpc.CallOption) (*proto.BatchGetResponse, error)
}

func (f *fakeKVClient) Get(ctx context.Context, in *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error) {
	if f.getFn != nil {
		return f.getFn(ctx, in, opts...)
	}
	return &proto.GetResponse{}, nil
}

func (f *fakeKVClient) BatchGet(ctx context.Context, in *proto.BatchGetRequest, opts ...grpc.CallOption) (*proto.BatchGetResponse, error) {
	if f.batchGetFn != nil {
		return f.batchGetFn(ctx, in, opts...)
	}

	resp := &proto.BatchGetResponse{Results: make([]*proto.BatchGetEntry, 0, len(in.GetKeys()))}
	for _, key := range in.GetKeys() {
		single, err := f.Get(ctx, &proto.GetRequest{Key: key}, opts...)
		if err != nil {
			return nil, err
		}
		resp.Results = append(resp.Results, &proto.BatchGetEntry{
			Key:      key,
			Value:    single.GetValue(),
			Found:    single.GetFound(),
			Revision: single.GetRevision(),
		})
	}

	return resp, nil
}

func (*fakeKVClient) Put(context.Context, *proto.PutRequest, ...grpc.CallOption) (*proto.PutResponse, error) {
	return &proto.PutResponse{}, nil
}

func (*fakeKVClient) PutIfAbsent(context.Context, *proto.PutRequest, ...grpc.CallOption) (*proto.PutResponse, error) {
	return &proto.PutResponse{}, nil
}

func (*fakeKVClient) PutMany(context.Context, *proto.PutManyRequest, ...grpc.CallOption) (*proto.PutManyResponse, error) {
	return &proto.PutManyResponse{}, nil
}

func (*fakeKVClient) Update(context.Context, *proto.UpdateRequest, ...grpc.CallOption) (*proto.UpdateResponse, error) {
	return &proto.UpdateResponse{}, nil
}

func (*fakeKVClient) Delete(context.Context, *proto.DeleteRequest, ...grpc.CallOption) (*proto.DeleteResponse, error) {
	return &proto.DeleteResponse{}, nil
}

func (*fakeKVClient) Watch(context.Context, *proto.WatchRequest, ...grpc.CallOption) (proto.KVService_WatchClient, error) {
	return nil, nil
}

func (*fakeKVClient) Info(context.Context, *proto.InfoRequest, ...grpc.CallOption) (*proto.InfoResponse, error) {
	return &proto.InfoResponse{}, nil
}

func TestProcessDevices_AttachesCanonicalMetadata(t *testing.T) {
	canonical := &identitymap.Record{CanonicalDeviceID: "canon-99", Partition: "prod", MetadataHash: "hash"}
	payload, err := identitymap.MarshalRecord(canonical)
	require.NoError(t, err)

	fake := &fakeKVClient{
		getFn: func(ctx context.Context, req *proto.GetRequest, _ ...grpc.CallOption) (*proto.GetResponse, error) {
			if strings.Contains(req.Key, "/armis-id/1") {
				return &proto.GetResponse{Value: payload, Found: true, Revision: 11}, nil
			}
			return &proto.GetResponse{Found: false}, nil
		},
	}

	integ := &ArmisIntegration{
		Config:   &models.SourceConfig{AgentID: "agent", PollerID: "poller", Partition: "part"},
		KVClient: fake,
		Logger:   logger.NewTestLogger(),
	}

	devices := []Device{{ID: 1, IPAddress: "192.168.1.1", MacAddress: "aa:bb", Name: "dev1"}}
	labels := map[int]string{1: "query"}
	queries := map[int]models.QueryConfig{1: {Label: "query", SweepModes: []models.SweepMode{models.ModeTCP}}}

	data, _, events, targets := integ.processDevices(context.Background(), devices, labels, queries)
	require.Len(t, events, 1)
	require.Equal(t, "canon-99", events[0].Metadata["canonical_device_id"])
	require.Equal(t, "11", events[0].Metadata["canonical_revision"])
	require.Equal(t, "prod", events[0].Metadata["canonical_partition"])
	require.Len(t, targets, 1)
	require.Equal(t, "canon-99", targets[0].Metadata["canonical_device_id"])
	require.Equal(t, "11", targets[0].Metadata["canonical_revision"])

	enrichedBlob, ok := data["1"]
	require.True(t, ok)
	var enriched DeviceWithMetadata
	require.NoError(t, json.Unmarshal(enrichedBlob, &enriched))
	require.Equal(t, "canon-99", enriched.Metadata["canonical_device_id"])
	require.Equal(t, "prod", enriched.Metadata["canonical_partition"])
}

func TestProcessDevices_PrefetchesCanonicalRecords(t *testing.T) {
	fake := &fakeKVClient{}
	var captured [][]string
	fake.batchGetFn = func(ctx context.Context, req *proto.BatchGetRequest, _ ...grpc.CallOption) (*proto.BatchGetResponse, error) {
		keys := append([]string(nil), req.GetKeys()...)
		captured = append(captured, keys)
		resp := &proto.BatchGetResponse{Results: make([]*proto.BatchGetEntry, len(keys))}
		for i, key := range keys {
			resp.Results[i] = &proto.BatchGetEntry{Key: key, Found: false}
		}
		return resp, nil
	}

	integ := &ArmisIntegration{
		Config:   &models.SourceConfig{AgentID: "agent", PollerID: "poller", Partition: "part"},
		KVClient: fake,
		Logger:   logger.NewTestLogger(),
	}

	devices := []Device{
		{ID: 1, IPAddress: "10.0.0.1,10.0.0.2", MacAddress: "aa:bb:cc:dd:ee:ff", Name: "dev1"},
		{ID: 2, IPAddress: "10.0.1.1", MacAddress: "11:22:33:44:55:66", Name: "dev2"},
	}

	labels := map[int]string{
		1: "query1",
		2: "query2",
	}

	queries := map[int]models.QueryConfig{
		1: {Label: "query1", SweepModes: []models.SweepMode{models.ModeTCP}},
		2: {Label: "query2", SweepModes: []models.SweepMode{models.ModeICMP}},
	}

	_, _, events, _ := integ.processDevices(context.Background(), devices, labels, queries)
	require.Len(t, events, 2)
	require.Len(t, captured, 1, "expected a single batched BatchGet call")

	uniquePaths := make(map[string]struct{})
	for _, event := range events {
		for _, key := range prioritizeIdentityKeys(identitymap.BuildKeys(event)) {
			uniquePaths[key.KeyPath(identitymap.DefaultNamespace)] = struct{}{}
		}
	}

	require.Len(t, captured[0], len(uniquePaths))
}

// keysWithPrefix returns map keys that have the given prefix
func keysWithPrefix(m map[string][]byte, prefix string) []string {
	var out []string

	for k := range m {
		if len(k) >= len(prefix) && k[:len(prefix)] == prefix {
			out = append(out, k)
		}
	}

	return out
}

func TestPrepareArmisUpdateFromDeviceStates(t *testing.T) {
	integ := &ArmisIntegration{Logger: logger.NewTestLogger()}
	states := []DeviceState{
		{IP: "1.1.1.1", IsAvailable: true, Metadata: map[string]interface{}{"armis_device_id": "10"}},
		{IP: "", IsAvailable: true, Metadata: map[string]interface{}{"armis_device_id": "11"}},
		{IP: "2.2.2.2", IsAvailable: false},
	}

	updates := integ.prepareArmisUpdateFromDeviceStates(states)
	require.Len(t, updates, 1)
	assert.Equal(t, 10, updates[0].DeviceID)
	assert.Equal(t, "1.1.1.1", updates[0].IP)
	// We're marking devices as OT_Isolation_Compliant in Armis if we CANT reach them
	assert.False(t, updates[0].Available)
}

func TestBatchUpdateDeviceAttributes_WithLargeDataset(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockTokenProvider := NewMockTokenProvider(ctrl)
	mockDeviceFetcher := NewMockDeviceFetcher(ctrl)
	mockKVWriter := NewMockKVWriter(ctrl)
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Setup integration
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint: "https://armis.example.com",
		},
		TokenProvider: mockTokenProvider,
		DeviceFetcher: mockDeviceFetcher,
		KVWriter:      mockKVWriter,
		Updater:       mockUpdater,
		Logger:        logger.NewTestLogger(),
	}

	// Create test data with 2500 devices (should be split into 5 batches of 500 each)
	const totalDevices = 2500

	devices := make([]Device, totalDevices)
	sweepResults := make([]SweepResult, totalDevices)

	for i := 0; i < totalDevices; i++ {
		devices[i] = Device{
			ID:        i + 1,
			IPAddress: fmt.Sprintf("192.168.%d.%d", (i/254)+1, (i%254)+1),
			Name:      fmt.Sprintf("Device-%d", i+1),
		}
		sweepResults[i] = SweepResult{
			IP:        fmt.Sprintf("192.168.%d.%d", (i/254)+1, (i%254)+1),
			Available: i%2 == 0, // Alternate between available and unavailable
			Timestamp: time.Now(),
		}
	}

	// Expect exactly 5 calls to UpdateMultipleDeviceCustomAttributes (500 devices each)
	mockUpdater.EXPECT().
		UpdateMultipleDeviceCustomAttributes(gomock.Any(), gomock.Len(500)).
		Return(nil).
		Times(5)

	// Execute the batch update
	ctx := context.Background()
	err := integration.BatchUpdateDeviceAttributes(ctx, devices, sweepResults)

	// Verify no error occurred
	assert.NoError(t, err)
}

func TestBatchUpdateDeviceAttributes_SingleBatch(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Setup integration
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint: "https://armis.example.com",
		},
		Updater: mockUpdater,
		Logger:  logger.NewTestLogger(),
	}

	// Create test data with 100 devices (single batch)
	const totalDevices = 100

	devices := make([]Device, totalDevices)
	sweepResults := make([]SweepResult, totalDevices)

	for i := 0; i < totalDevices; i++ {
		devices[i] = Device{
			ID:        i + 1,
			IPAddress: fmt.Sprintf("192.168.1.%d", i+1),
			Name:      fmt.Sprintf("Device-%d", i+1),
		}
		sweepResults[i] = SweepResult{
			IP:        fmt.Sprintf("192.168.1.%d", i+1),
			Available: true,
			Timestamp: time.Now(),
		}
	}

	// Expect exactly 1 call to UpdateMultipleDeviceCustomAttributes with all devices
	mockUpdater.EXPECT().
		UpdateMultipleDeviceCustomAttributes(gomock.Any(), gomock.Len(100)).
		Return(nil).
		Times(1)

	// Execute the batch update
	ctx := context.Background()
	err := integration.BatchUpdateDeviceAttributes(ctx, devices, sweepResults)

	// Verify no error occurred
	assert.NoError(t, err)
}

func TestBatchUpdateDeviceAttributes_WithCustomBatchSize(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Setup integration with custom batch size
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint:  "https://armis.example.com",
			BatchSize: 250, // Custom batch size
		},
		Updater: mockUpdater,
		Logger:  logger.NewTestLogger(),
	}

	// Create test data with 750 devices (should be split into 3 batches of 250 each)
	const totalDevices = 750

	devices := make([]Device, totalDevices)
	sweepResults := make([]SweepResult, totalDevices)

	for i := 0; i < totalDevices; i++ {
		devices[i] = Device{
			ID:        i + 1,
			IPAddress: fmt.Sprintf("192.168.%d.%d", (i/254)+1, (i%254)+1),
			Name:      fmt.Sprintf("Device-%d", i+1),
		}
		sweepResults[i] = SweepResult{
			IP:        fmt.Sprintf("192.168.%d.%d", (i/254)+1, (i%254)+1),
			Available: i%2 == 0,
			Timestamp: time.Now(),
		}
	}

	// Expect exactly 3 calls with 250 devices each
	mockUpdater.EXPECT().
		UpdateMultipleDeviceCustomAttributes(gomock.Any(), gomock.Len(250)).
		Return(nil).
		Times(3)

	// Execute the batch update
	ctx := context.Background()
	err := integration.BatchUpdateDeviceAttributes(ctx, devices, sweepResults)

	// Verify no error occurred
	assert.NoError(t, err)
}

func TestArmisIntegration_Reconcile_SimpleUpdate(t *testing.T) {
	integration, mocks := setupArmisIntegration(t)

	// Test data
	ctx := context.Background()

	// Existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition/192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "1",
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			IsAvailable: false,
			Metadata: map[string]interface{}{
				"armis_device_id": "2",
			},
		},
	}

	// Setup expectations
	mocks.SweepQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Mock the Armis updater to verify the updates
	mocks.Updater.EXPECT().
		UpdateDeviceStatus(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []ArmisDeviceStatus) error {
			require.Len(t, updates, 2)

			// Device 1 is available in ServiceRadar, so it should be marked as NOT available in Armis
			assert.Equal(t, 1, updates[0].DeviceID)
			assert.Equal(t, "192.168.1.1", updates[0].IP)
			assert.False(t, updates[0].Available)

			// Device 2 is NOT available in ServiceRadar, so it should be marked as available in Armis
			assert.Equal(t, 2, updates[1].DeviceID)
			assert.Equal(t, "192.168.1.2", updates[1].IP)
			assert.True(t, updates[1].Available)

			return nil
		})

	// Execute the reconcile operation
	err := integration.Reconcile(ctx)
	require.NoError(t, err)
}

func TestArmisIntegration_Reconcile_EmptyDeviceStates(t *testing.T) {
	integration, mocks := setupArmisIntegration(t)

	// Test data
	ctx := context.Background()

	// No existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{}

	// Setup expectations
	mocks.SweepQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Updater should not be called since there are no device states

	// Execute the reconcile operation
	err := integration.Reconcile(ctx)
	require.NoError(t, err)
}

func TestArmisIntegration_Reconcile_UpdaterError(t *testing.T) {
	integration, mocks := setupArmisIntegration(t)

	// Test data
	ctx := context.Background()
	expectedError := assert.AnError

	// Existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition/192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "1",
			},
		},
	}

	// Setup expectations
	mocks.SweepQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Mock the updater to return an error
	mocks.Updater.EXPECT().
		UpdateDeviceStatus(ctx, gomock.Any()).
		Return(expectedError)

	// Execute the reconcile operation - should return error
	err := integration.Reconcile(ctx)
	require.Error(t, err)
	// The error is now wrapped with batch information, so we check if it contains the original error
	assert.Contains(t, err.Error(), expectedError.Error())
}

func TestArmisIntegration_Reconcile_NoUpdater(t *testing.T) {
	integration, _ := setupArmisIntegration(t)

	// Clear the updater to simulate no updater configured
	integration.Updater = nil

	// Execute the reconcile operation - should succeed with early return
	err := integration.Reconcile(context.Background())
	require.NoError(t, err)
}

func TestArmisIntegration_Reconcile_QueryError(t *testing.T) {
	integration, mocks := setupArmisIntegration(t)

	// Test data
	ctx := context.Background()
	expectedError := assert.AnError

	// Setup expectations - querier returns error
	mocks.SweepQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(nil, expectedError)

	// Execute the reconcile operation - should return error
	err := integration.Reconcile(ctx)
	require.Error(t, err)
	assert.Equal(t, expectedError, err)
}

// TestArmisIntegration_Fetch_PerDeviceSweepModes tests that devices from different queries
// get associated with their query's specific sweep modes.
func TestArmisIntegration_Fetch_PerDeviceSweepModes(t *testing.T) {
	integration, mocks := setupArmisIntegration(t)
	integration.Updater = nil
	integration.SweepQuerier = nil

	// Configure multiple queries with different sweep modes
	integration.Config.Queries = []models.QueryConfig{
		{
			Label:      "tcp_devices",
			Query:      "in:devices boundaries:\"Corporate\"",
			SweepModes: []models.SweepMode{models.ModeTCP},
		},
		{
			Label:      "icmp_devices",
			Query:      "in:devices boundaries:\"Guest\"",
			SweepModes: []models.SweepMode{models.ModeICMP},
		},
		{
			Label:      "both_modes_devices",
			Query:      "in:devices boundaries:\"Lab\"",
			SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
		},
	}

	// Mock devices for each query
	tcpDevices := []Device{
		{ID: 1, IPAddress: "192.168.1.10", Name: "tcp-server"},
	}
	icmpDevices := []Device{
		{ID: 2, IPAddress: "192.168.1.20", Name: "icmp-device"},
	}
	bothModesDevices := []Device{
		{ID: 3, IPAddress: "192.168.1.30", Name: "hybrid-device"},
	}

	ctx := context.Background()

	// Mock responses for each query
	mocks.TokenProvider.EXPECT().GetAccessToken(ctx).Return("test-token", nil)
	// First query (TCP devices)
	mocks.DeviceFetcher.EXPECT().
		FetchDevicesPage(ctx, "test-token", "in:devices boundaries:\"Corporate\"", 0, 100).
		Return(&SearchResponse{
			Success: true,
			Data: struct {
				Count   int         `json:"count"`
				Next    int         `json:"next"`
				Prev    interface{} `json:"prev"`
				Results []Device    `json:"results"`
				Total   int         `json:"total"`
			}{
				Count:   1,
				Results: tcpDevices,
				Next:    0,
			},
		}, nil)

	// Second query (ICMP devices)
	mocks.DeviceFetcher.EXPECT().
		FetchDevicesPage(ctx, "test-token", "in:devices boundaries:\"Guest\"", 0, 100).
		Return(&SearchResponse{
			Success: true,
			Data: struct {
				Count   int         `json:"count"`
				Next    int         `json:"next"`
				Prev    interface{} `json:"prev"`
				Results []Device    `json:"results"`
				Total   int         `json:"total"`
			}{
				Count:   1,
				Results: icmpDevices,
				Next:    0,
			},
		}, nil)

	// Third query (both modes devices)
	mocks.DeviceFetcher.EXPECT().
		FetchDevicesPage(ctx, "test-token", "in:devices boundaries:\"Lab\"", 0, 100).
		Return(&SearchResponse{
			Success: true,
			Data: struct {
				Count   int         `json:"count"`
				Next    int         `json:"next"`
				Prev    interface{} `json:"prev"`
				Results []Device    `json:"results"`
				Total   int         `json:"total"`
			}{
				Count:   1,
				Results: bothModesDevices,
				Next:    0,
			},
		}, nil)

	// Mock KV writer to capture the sweep config
	var capturedSweepConfig *models.SweepConfig

	mocks.KVWriter.EXPECT().
		WriteSweepConfig(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, config *models.SweepConfig) error {
			capturedSweepConfig = config
			return nil
		})

	// Execute fetch
	kvData, deviceUpdates, err := integration.Fetch(ctx)

	// Verify no errors
	require.NoError(t, err)
	require.NotNil(t, kvData)
	require.NotNil(t, deviceUpdates)
	require.NotNil(t, capturedSweepConfig)

	// Verify device updates contain correct metadata
	assert.Len(t, deviceUpdates, 3)

	// Find device updates by IP
	var tcpDevice, icmpDevice, bothModesDevice *models.DeviceUpdate

	for _, update := range deviceUpdates {
		switch update.IP {
		case "192.168.1.10":
			tcpDevice = update
		case "192.168.1.20":
			icmpDevice = update
		case "192.168.1.30":
			bothModesDevice = update
		}
	}

	// Verify device updates have correct query labels
	require.NotNil(t, tcpDevice)
	assert.Equal(t, "tcp_devices", tcpDevice.Metadata["query_label"])

	require.NotNil(t, icmpDevice)
	assert.Equal(t, "icmp_devices", icmpDevice.Metadata["query_label"])
	require.NotNil(t, bothModesDevice)
	assert.Equal(t, "both_modes_devices", bothModesDevice.Metadata["query_label"])

	// Verify sweep config contains device targets with correct sweep modes
	assert.Len(t, capturedSweepConfig.DeviceTargets, 3)

	// Find device targets by network
	var tcpTarget, icmpTarget, bothModesTarget *models.DeviceTarget

	for i := range capturedSweepConfig.DeviceTargets {
		target := &capturedSweepConfig.DeviceTargets[i]
		switch target.Network {
		case "192.168.1.10/32":
			tcpTarget = target
		case "192.168.1.20/32":
			icmpTarget = target
		case "192.168.1.30/32":
			bothModesTarget = target
		}
	}

	// Verify TCP device target
	require.NotNil(t, tcpTarget)
	assert.Equal(t, []models.SweepMode{models.ModeTCP}, tcpTarget.SweepModes)
	assert.Equal(t, "tcp_devices", tcpTarget.QueryLabel)
	assert.Equal(t, "armis", tcpTarget.Source)

	// Verify ICMP device target
	require.NotNil(t, icmpTarget)
	assert.Equal(t, []models.SweepMode{models.ModeICMP}, icmpTarget.SweepModes)
	assert.Equal(t, "icmp_devices", icmpTarget.QueryLabel)
	assert.Equal(t, "armis", icmpTarget.Source)

	// Verify both modes device target
	require.NotNil(t, bothModesTarget)
	assert.Equal(t, []models.SweepMode{models.ModeICMP, models.ModeTCP}, bothModesTarget.SweepModes)
	assert.Equal(t, "both_modes_devices", bothModesTarget.QueryLabel)
	assert.Equal(t, "armis", bothModesTarget.Source)

	// Verify metadata is preserved
	assert.Equal(t, "1", tcpTarget.Metadata["armis_device_id"])
	assert.Equal(t, "2", icmpTarget.Metadata["armis_device_id"])
	assert.Equal(t, "3", bothModesTarget.Metadata["armis_device_id"])
}
