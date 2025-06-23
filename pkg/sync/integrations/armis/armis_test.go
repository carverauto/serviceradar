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

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
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
	}

	setupArmisMocks(t, mocks, firstPageResp, expectedSweepConfig)

	result, events, err := integration.Fetch(context.Background())
	verifyArmisResults(t, result, events, err, expectedDevices)

	// Ensure that the enrichment data was not added
	_, exists := result["_sweep_results"]
	assert.False(t, exists)
}

// TestArmisIntegration_Fetch_WithUpdaterAndCorrelation tests the full fetch/correlation/update workflow.
func TestArmisIntegration_Fetch_WithUpdaterAndCorrelation(t *testing.T) {
	// 1. Setup
	integration, mocks := setupArmisIntegration(t)
	expectedDevices := getExpectedDevices()
	firstPageResp := getFirstPageResponse(expectedDevices)

	// Mock sweep results, one for each device IP
	mockSweepResults := []SweepResult{
		{IP: "192.168.1.1", Available: true, Timestamp: time.Now(), RTT: 15.5},
		{IP: "192.168.1.2", Available: false, Timestamp: time.Now(), Error: "timeout"},
	}

	// 2. Define mock expectations
	testAccessToken := "test-access-token"
	expectedQuery := "in:devices orderBy=id boundaries:\"Corporate\""

	// Expectations for the initial device fetch
	mocks.TokenProvider.EXPECT().GetAccessToken(gomock.Any()).Return(testAccessToken, nil)
	mocks.DeviceFetcher.EXPECT().FetchDevicesPage(gomock.Any(), testAccessToken, expectedQuery, 0, 100).Return(firstPageResp, nil)
	mocks.KVWriter.EXPECT().WriteSweepConfig(gomock.Any(), gomock.Any()).Return(nil)

	// Expectations for the new correlation logic
	mocks.SweepQuerier.EXPECT().GetTodaysSweepResults(gomock.Any()).Return(mockSweepResults, nil)
	mocks.Updater.EXPECT().UpdateDeviceStatus(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []ArmisDeviceStatus) error {
			// Verify the content of the updates being sent to Armis
			require.Len(t, updates, 2)

			// Device 1 had a sweep result and was available
			assert.Equal(t, 1, updates[0].DeviceID)
			assert.Equal(t, "192.168.1.1", updates[0].IP)
			assert.True(t, updates[0].Available)
			assert.InEpsilon(t, 15.5, updates[0].RTT, 0.0001)

			// Device 2 had a sweep result and was not available
			assert.Equal(t, 2, updates[1].DeviceID)
			assert.Equal(t, "192.168.1.2", updates[1].IP)
			assert.False(t, updates[1].Available)

			return nil
		}).Return(nil)

	// 3. Execute the method under test
	result, _, err := integration.Fetch(context.Background())

	// 4. Assert the results
	require.NoError(t, err)
	require.NotNil(t, result)

	// Expect 6 items: 5 device entries + 1 for "_sweep_results"
	expectedLen := len(expectedDevices)

	for i := range expectedDevices {
		ip := extractFirstIP(expectedDevices[i].IPAddress)
		if ip != "" {
			expectedLen++
		}
	}

	if _, ok := result["_sweep_results"]; ok {
		expectedLen++
	}

	assert.Len(t, result, expectedLen)

	// Verify original devices are still present in the result map
	_, device1Exists := result["1"]
	assert.True(t, device1Exists)

	_, device2Exists := result["2"]
	assert.True(t, device2Exists)

	// Verify that the sweep results were added to the map for enrichment
	sweepResultsData, sweepResultsExist := result["_sweep_results"]
	require.True(t, sweepResultsExist)

	var storedSweepResults []SweepResult

	err = json.Unmarshal(sweepResultsData, &storedSweepResults)
	require.NoError(t, err)

	assert.Len(t, storedSweepResults, 2)
	assert.Equal(t, "192.168.1.1", storedSweepResults[0].IP)
}

func setupArmisIntegration(t *testing.T) (*ArmisIntegration, *armisMocks) {
	t.Helper()
	ctrl := gomock.NewController(t)
	mocks := &armisMocks{
		TokenProvider: NewMockTokenProvider(ctrl),
		DeviceFetcher: NewMockDeviceFetcher(ctrl),
		KVWriter:      NewMockKVWriter(ctrl),
		SweepQuerier:  NewMockSweepResultsQuerier(ctrl),
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
				"boundary":   "Corporate",
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
	}, mocks
}

type armisMocks struct {
	TokenProvider *MockTokenProvider
	DeviceFetcher *MockDeviceFetcher
	KVWriter      *MockKVWriter
	SweepQuerier  *MockSweepResultsQuerier
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

func setupArmisMocks(t *testing.T, mocks *armisMocks, resp *SearchResponse, expectedSweepConfig *models.SweepConfig) {
	t.Helper()

	testAccessToken := "test-access-token"
	expectedQuery := "in:devices orderBy=id boundaries:\"Corporate\""

	mocks.TokenProvider.EXPECT().GetAccessToken(gomock.Any()).Return(testAccessToken, nil)
	mocks.DeviceFetcher.EXPECT().FetchDevicesPage(gomock.Any(), testAccessToken, expectedQuery, 0, 100).Return(resp, nil)
	mocks.KVWriter.EXPECT().WriteSweepConfig(gomock.Any(), expectedSweepConfig).Return(nil)
}

func verifyArmisResults(t *testing.T, result map[string][]byte, events []*models.SweepResult, err error, expectedDevices []Device) {
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

		key := fmt.Sprintf("test-partition:%s", ip)
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
	}

	testAccessToken := "test-access-token"
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
	expectedSweepConfig := &models.SweepConfig{
		Networks: []string{"192.168.1.1/32", "192.168.1.2/32", "192.168.1.3/32", "192.168.1.4/32"},
	}

	integration.TokenProvider.(*MockTokenProvider).
		EXPECT().GetAccessToken(gomock.Any()).Return(testAccessToken, nil)
	integration.DeviceFetcher.(*MockDeviceFetcher).
		EXPECT().FetchDevicesPage(gomock.Any(), testAccessToken, expectedQuery, 0, 50).Return(firstPageResp, nil)
	integration.DeviceFetcher.(*MockDeviceFetcher).
		EXPECT().FetchDevicesPage(gomock.Any(), testAccessToken, expectedQuery, 2, 50).Return(secondPageResp, nil)
	integration.KVWriter.(*MockKVWriter).
		EXPECT().WriteSweepConfig(gomock.Any(), expectedSweepConfig).Return(nil)

	result, _, err := integration.Fetch(context.Background())

	require.NoError(t, err)
	require.NotNil(t, result)

	assert.Len(t, result, 8)

	for i := 1; i <= 4; i++ {
		key := fmt.Sprintf("test-partition:192.168.1.%d", i)
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
					EXPECT().WriteSweepConfig(gomock.Any(),
					&models.SweepConfig{Networks: []string{"192.168.1.1/32"}}).Return(errKVWriteError)
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
				defer mockResponse.Body.Close()
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

	return &DefaultArmisIntegration{Config: &models.SourceConfig{Endpoint: "https://armis.example.com"}, HTTPClient: mockHTTPClient}
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
			expectedToken: "test-access-token",
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

func (mr *mockKVClientRecorder) Put(ctx, in interface{}, opts ...interface{}) *gomock.Call {
	mr.mock.ctrl.T.Helper()

	varargs := append([]interface{}{ctx, in}, opts...)

	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Put", reflect.TypeOf((*mockKVClient)(nil).Put), varargs...)
}

func (*mockKVClient) Get(_ context.Context, _ *proto.GetRequest, _ ...grpc.CallOption) (*proto.GetResponse, error) {
	return nil, errNotImplemented
}
func (*mockKVClient) Delete(_ context.Context, _ *proto.DeleteRequest, _ ...grpc.CallOption) (*proto.DeleteResponse, error) {
	return nil, errNotImplemented
}
func (*mockKVClient) Watch(_ context.Context, _ *proto.WatchRequest, _ ...grpc.CallOption) (proto.KVService_WatchClient, error) {
	return nil, errNotImplemented
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
				t.Log("Setting up mock expectation for Put")
				mock.Put(gomock.Any(), gomock.Any(), gomock.Any()).
					DoAndReturn(func(_ context.Context, req *proto.PutRequest, _ ...grpc.CallOption) (*proto.PutResponse, error) {
						assert.Equal(t, "agents/test-server/checkers/sweep/sweep.json", req.Key)

						var config models.SweepConfig

						err := json.Unmarshal(req.Value, &config)
						require.NoError(t, err)
						assert.Equal(t, testSweepConfig.Networks, config.Networks)

						return &proto.PutResponse{}, nil
					})
			},
			expectedError: "",
		},
		{
			name: "KV client error",
			setupMock: func(mock *mockKVClientRecorder) {
				t.Log("Setting up mock expectation for Put with error")
				mock.Put(gomock.Any(), gomock.Any(), gomock.Any()).Return(nil, errNetworkError)
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

			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`{"success": true}`))}, nil
		},
	)

	err := updater.UpdateDeviceStatus(context.Background(), updates)
	require.NoError(t, err)
}
