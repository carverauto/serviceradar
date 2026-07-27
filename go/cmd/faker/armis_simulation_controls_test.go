package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestArmisSimulationControlsReportReadinessAndPreserveIPCardinality(t *testing.T) {
	originalGenerator := deviceGen
	originalConfig := config
	originalSequence := simulationChurnSequence
	t.Cleanup(func() {
		deviceGen = originalGenerator
		config = originalConfig
		simulationChurnSequence = originalSequence
	})

	config = &Config{}
	config.Simulation.IPShuffle.Seed = 4707
	deviceGen = &DeviceGenerator{
		allDevices: []ArmisDevice{
			{ID: 1, IPAddress: "10.0.0.1"},
			{ID: 2, IPAddress: "10.0.0.2"},
			{ID: 3, IPAddress: "10.0.0.3"},
		},
	}
	initialDevices := append([]ArmisDevice(nil), deviceGen.allDevices...)
	simulationChurnSequence = 0

	readyRecorder := httptest.NewRecorder()
	armisReadyHandler(
		readyRecorder,
		httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/debug/armis/ready", nil),
	)
	require.Equal(t, http.StatusOK, readyRecorder.Code)

	var readyResponse struct {
		Success bool `json:"success"`
		Data    struct {
			DeviceCount int `json:"device_count"`
		} `json:"data"`
	}
	require.NoError(t, json.Unmarshal(readyRecorder.Body.Bytes(), &readyResponse))
	require.True(t, readyResponse.Success)
	require.Equal(t, 3, readyResponse.Data.DeviceCount)

	churnRecorder := httptest.NewRecorder()
	body, err := json.Marshal(map[string]int{"swaps": 20})
	require.NoError(t, err)
	armisChurnHandler(
		churnRecorder,
		httptest.NewRequestWithContext(
			context.Background(),
			http.MethodPost,
			"/debug/armis/simulation/churn",
			bytes.NewReader(body),
		),
	)
	require.Equal(t, http.StatusOK, churnRecorder.Code)

	seen := make(map[string]struct{}, len(deviceGen.allDevices))
	for _, device := range deviceGen.allDevices {
		seen[primaryIP(device.IPAddress)] = struct{}{}
	}
	require.Len(t, seen, 3)

	firstChurn := make(map[int]string, len(deviceGen.allDevices))
	for _, device := range deviceGen.allDevices {
		firstChurn[device.ID] = device.IPAddress
	}
	deviceGen.allDevices = append([]ArmisDevice(nil), initialDevices...)
	simulationChurnSequence = 0

	secondChurnRecorder := httptest.NewRecorder()
	armisChurnHandler(
		secondChurnRecorder,
		httptest.NewRequestWithContext(
			context.Background(),
			http.MethodPost,
			"/debug/armis/simulation/churn",
			bytes.NewReader(body),
		),
	)
	require.Equal(t, http.StatusOK, secondChurnRecorder.Code)

	secondChurn := make(map[int]string, len(deviceGen.allDevices))
	for _, device := range deviceGen.allDevices {
		secondChurn[device.ID] = device.IPAddress
	}
	require.Equal(t, firstChurn, secondChurn)
}
