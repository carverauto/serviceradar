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
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
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

	setupArmisMocks(t, mocks, firstPageResp)

	events, err := integration.Fetch(context.Background())
	verifyArmisResults(t, events, err, expectedDevices)
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

	// 3. Execute Fetch (Discovery only)
	events, err := integration.Fetch(context.Background())

	// 4. Assert Fetch results (Discovery only)
	require.NoError(t, err)
	// Verify devices and sweep results
	verifyArmisResults(t, events, err, expectedDevices)

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
		SweepQuerier:  mocks.SweepQuerier,
		Updater:       mocks.Updater,
		Logger:        logger.NewTestLogger(),
	}, mocks
}

type armisMocks struct {
	TokenProvider *MockTokenProvider
	DeviceFetcher *MockDeviceFetcher
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

func setupArmisMocks(t *testing.T, mocks *armisMocks, resp *SearchResponse) {
	t.Helper()

	testAccessToken := testAccessToken
	expectedQuery := "in:devices orderBy=id boundaries:\"Corporate\""

	mocks.TokenProvider.EXPECT().GetAccessToken(gomock.Any()).Return(testAccessToken, nil)
	mocks.DeviceFetcher.EXPECT().FetchDevicesPage(gomock.Any(), testAccessToken, expectedQuery, 0, 100).Return(resp, nil)
}

func verifyArmisResults(t *testing.T, events []*models.DeviceUpdate, err error, expectedDevices []Device) {
	t.Helper()

	require.NoError(t, err)

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

	events, err := integration.Fetch(context.Background())

	require.NoError(t, err)
	require.Len(t, events, 4)
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
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			tc.setupMocks(integration)

			events, err := integration.Fetch(context.Background())
			if tc.expectedError != "" {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tc.expectedError)
				assert.Nil(t, events)
			} else {
				require.NoError(t, err)
				require.NotNil(t, events)
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
	}

	events, err := integration.Fetch(context.Background())

	assert.Nil(t, events)
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

	// Execute the fetch
	events, err := integration.Fetch(context.Background())

	// Verify no errors
	require.NoError(t, err)
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

	t.Log("Successfully verified that multiple queries are accumulated in memory")
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

// TestProcessDevices verifies that Armis devices are converted into DeviceUpdate events.
func TestProcessDevices(t *testing.T) {
	integ := &ArmisIntegration{
		Config: &models.SourceConfig{AgentID: "test-agent", PollerID: "poller", Partition: "part"},
		Logger: logger.NewTestLogger(),
	}

	devices := []Device{
		{ID: 1, IPAddress: "192.168.1.1", MacAddress: "aa:bb:cc:dd:ee:ff", Name: "dev1", Tags: []string{"t1"}},
		{ID: 2, IPAddress: "192.168.1.2,10.0.0.1", MacAddress: "cc:dd:ee:ff:00:11", Name: "dev2"},
	}

	deviceLabels := map[int]string{
		1: "test_query_1",
		2: "test_query_2",
	}

	events := integ.processDevices(context.Background(), devices, deviceLabels)

	// Verify events were created correctly
	require.Len(t, events, 2, "should have one event per device")

	// Check first event
	assert.Equal(t, "test-agent", events[0].AgentID)
	assert.Equal(t, "poller", events[0].PollerID)
	assert.Equal(t, "192.168.1.1", events[0].IP)
	assert.Empty(t, events[0].DeviceID) // Empty - registry will generate ServiceRadar UUID
	assert.Equal(t, "part", events[0].Partition)
	assert.Equal(t, models.DiscoverySourceArmis, events[0].Source)
	assert.False(t, events[0].IsAvailable) // Defaults to false in discovery, actual availability comes from sweep
	assert.NotNil(t, events[0].Hostname)
	assert.Equal(t, "dev1", *events[0].Hostname)
	assert.NotNil(t, events[0].MAC)
	assert.Equal(t, "AA:BB:CC:DD:EE:FF", *events[0].MAC)
	assert.NotNil(t, events[0].Metadata)
	assert.Equal(t, "armis", events[0].Metadata["integration_type"])
	assert.Equal(t, "1", events[0].Metadata["integration_id"])
	assert.Equal(t, "1", events[0].Metadata["armis_device_id"])
	assert.Equal(t, "test_query_1", events[0].Metadata["query_label"])

	// Check second event
	assert.Equal(t, "test-agent", events[1].AgentID)
	assert.Equal(t, "poller", events[1].PollerID)
	assert.Equal(t, "192.168.1.2", events[1].IP)
	assert.Empty(t, events[1].DeviceID) // Empty - registry will generate ServiceRadar UUID
	assert.Equal(t, "part", events[1].Partition)
	assert.Equal(t, models.DiscoverySourceArmis, events[1].Source)
	assert.False(t, events[1].IsAvailable) // Defaults to false in discovery, actual availability comes from sweep
	assert.NotNil(t, events[1].Hostname)
	assert.Equal(t, "dev2", *events[1].Hostname)
	assert.NotNil(t, events[1].MAC)
	assert.Equal(t, "CC:DD:EE:FF:00:11", *events[1].MAC)
	assert.NotNil(t, events[1].Metadata)
	assert.Equal(t, "armis", events[1].Metadata["integration_type"])
	assert.Equal(t, "2", events[1].Metadata["integration_id"])
	assert.Equal(t, "2", events[1].Metadata["armis_device_id"])
	assert.Equal(t, "test_query_2", events[1].Metadata["query_label"])
}

func TestDeviceAggregatorAggregatesByID(t *testing.T) {
	agg := newDeviceAggregator()

	tcpQuery := models.QueryConfig{Label: "tcp_devices", SweepModes: []models.SweepMode{models.ModeTCP}}
	icmpQuery := models.QueryConfig{Label: "icmp_devices", SweepModes: []models.SweepMode{models.ModeICMP}}

	device := Device{
		ID:        42,
		IPAddress: "10.0.0.1",
		Name:      "example",
		Tags:      []string{"tag1"},
	}

	duplicate := Device{
		ID:        42,
		IPAddress: "10.0.0.2,10.0.0.1",
		Name:      "example",
		Tags:      []string{"tag2"},
	}

	agg.addDevice(device, tcpQuery)
	agg.addDevice(duplicate, icmpQuery)

	devices, labels, queries := agg.materialize()

	require.Len(t, devices, 1)
	assert.Equal(t, "10.0.0.1,10.0.0.2", devices[0].IPAddress)
	assert.ElementsMatch(t, []string{"tag1", "tag2"}, devices[0].Tags)

	label, ok := labels[42]
	require.True(t, ok)
	assert.Equal(t, "icmp_devices,tcp_devices", label)

	queryCfg, ok := queries[42]
	require.True(t, ok)
	assert.ElementsMatch(t, []models.SweepMode{models.ModeTCP, models.ModeICMP}, queryCfg.SweepModes)
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
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Setup integration
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint: "https://armis.example.com",
		},
		TokenProvider: mockTokenProvider,
		DeviceFetcher: mockDeviceFetcher,
		Updater:       mockUpdater,
		Logger:        logger.NewTestLogger(),
	}

	// Create test data with 1500 devices (should be split into 3 batches of 500 each)
	const totalDevices = 1500

	devices := make([]Device, totalDevices)
	sweepResults := make([]SweepResult, totalDevices)
	now := time.Now()

	for i := 0; i < totalDevices; i++ {
		devices[i] = Device{
			ID:        i + 1,
			IPAddress: fmt.Sprintf("192.168.%d.%d", (i/254)+1, (i%254)+1),
			Name:      fmt.Sprintf("Device-%d", i+1),
		}
		sweepResults[i] = SweepResult{
			IP:        fmt.Sprintf("192.168.%d.%d", (i/254)+1, (i%254)+1),
			Available: i%2 == 0, // Alternate between available and unavailable
			Timestamp: now,
		}
	}

	// Expect exactly 3 calls to UpdateMultipleDeviceCustomAttributes (500 devices each)
	mockUpdater.EXPECT().
		UpdateMultipleDeviceCustomAttributes(gomock.Any(), gomock.Len(500)).
		Return(nil).
		Times(3)

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

	// Execute fetch
	deviceUpdates, err := integration.Fetch(ctx)

	// Verify no errors
	require.NoError(t, err)
	require.NotNil(t, deviceUpdates)

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
}
