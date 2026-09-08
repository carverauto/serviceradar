package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestBulkCustomPropertiesHandlerSupportsBulkCustomPropertiesPayload(t *testing.T) {
	resetNorthboundUpdates()

	deviceGen = &DeviceGenerator{
		allDevices: []ArmisDevice{{ID: 101, Name: "device-101"}},
	}

	body, err := json.Marshal([]bulkCustomPropertyOperation{
		{
			ID: "101",
			CustomProperties: map[string]interface{}{
				"availability": true,
			},
		},
	})
	require.NoError(t, err)

	req := httptest.NewRequestWithContext(context.Background(), http.MethodPost, "/api/v1/devices/custom-properties/_bulk/", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer fake-token-test")

	rr := httptest.NewRecorder()
	bulkCustomPropertiesHandler(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)

	props, ok := deviceGen.allDevices[0].CustomProperties.(map[string]interface{})
	require.True(t, ok)
	require.Equal(t, true, props["availability"])

	updates := northboundUpdatesSnapshot()
	require.True(t, updates.Success)
	require.Equal(t, 1, updates.Data.Total)
	require.Equal(t, 1, updates.Data.Updated)
	require.Equal(t, 0, updates.Data.Missing)
	require.Equal(t, map[string]int{"availability": 1}, updates.Data.Fields)
	require.Len(t, updates.Data.Results, 1)
	require.Equal(t, "101", updates.Data.Results[0].DeviceID)
	require.Equal(t, "customProperties", updates.Data.Results[0].PayloadShape)
	require.Equal(t, true, updates.Data.Results[0].Properties["availability"])
}

func TestBulkCustomPropertiesHandlerSupportsLegacyUpsertPayload(t *testing.T) {
	resetNorthboundUpdates()

	deviceGen = &DeviceGenerator{
		allDevices: []ArmisDevice{{ID: 202, Name: "device-202"}},
	}

	body, err := json.Marshal([]bulkCustomPropertyOperation{
		{
			Upsert: &struct {
				DeviceID int         `json:"deviceId"`
				Key      string      `json:"key"`
				Value    interface{} `json:"value"`
			}{
				DeviceID: 202,
				Key:      "availability",
				Value:    false,
			},
		},
	})
	require.NoError(t, err)

	req := httptest.NewRequestWithContext(context.Background(), http.MethodPost, "/api/v1/devices/custom-properties/_bulk/", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer fake-token-test")

	rr := httptest.NewRecorder()
	bulkCustomPropertiesHandler(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)

	props, ok := deviceGen.allDevices[0].CustomProperties.(map[string]interface{})
	require.True(t, ok)
	require.Equal(t, false, props["availability"])

	updates := northboundUpdatesSnapshot()
	require.Equal(t, 1, updates.Data.Total)
	require.Equal(t, 1, updates.Data.Updated)
	require.Equal(t, "202", updates.Data.Results[0].DeviceID)
	require.Equal(t, "upsert", updates.Data.Results[0].PayloadShape)
	require.Equal(t, false, updates.Data.Results[0].Properties["availability"])
}

func TestNorthboundUpdatesHandlerExposesAndResetsCapturedBulkUpdates(t *testing.T) {
	resetNorthboundUpdates()
	recordNorthboundUpdate("303", map[string]interface{}{"OT_Isolation_Compliant": true}, true, "upsert", fixedTestTime())
	recordNorthboundUpdate("404", map[string]interface{}{"OT_Isolation_Compliant": false}, false, "customProperties", fixedTestTime())

	getReq := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/debug/armis/northbound/updates", nil)
	getRecorder := httptest.NewRecorder()
	northboundUpdatesHandler(getRecorder, getReq)

	require.Equal(t, http.StatusOK, getRecorder.Code)

	var response northboundUpdatesResponse
	require.NoError(t, json.Unmarshal(getRecorder.Body.Bytes(), &response))
	require.True(t, response.Success)
	require.Equal(t, 2, response.Data.Total)
	require.Equal(t, 1, response.Data.Updated)
	require.Equal(t, 1, response.Data.Missing)
	require.Equal(t, map[string]int{"OT_Isolation_Compliant": 2}, response.Data.Fields)
	require.Len(t, response.Data.Results, 2)
	require.Equal(t, int64(1), response.Data.Results[0].Sequence)
	require.Equal(t, "303", response.Data.Results[0].DeviceID)

	deleteReq := httptest.NewRequestWithContext(context.Background(), http.MethodDelete, "/debug/armis/northbound/updates", nil)
	deleteRecorder := httptest.NewRecorder()
	northboundUpdatesHandler(deleteRecorder, deleteReq)
	require.Equal(t, http.StatusOK, deleteRecorder.Code)

	require.Equal(t, 0, northboundUpdatesSnapshot().Data.Total)
}

func fixedTestTime() time.Time {
	return time.Date(2026, 5, 19, 20, 0, 0, 0, time.UTC)
}
