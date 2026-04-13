package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestBulkCustomPropertiesHandlerSupportsBulkCustomPropertiesPayload(t *testing.T) {
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

	req := httptest.NewRequest(http.MethodPost, "/api/v1/devices/custom-properties/_bulk/", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer fake-token-test")

	rr := httptest.NewRecorder()
	bulkCustomPropertiesHandler(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)

	props, ok := deviceGen.allDevices[0].CustomProperties.(map[string]interface{})
	require.True(t, ok)
	require.Equal(t, true, props["availability"])
}

func TestBulkCustomPropertiesHandlerSupportsLegacyUpsertPayload(t *testing.T) {
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

	req := httptest.NewRequest(http.MethodPost, "/api/v1/devices/custom-properties/_bulk/", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer fake-token-test")

	rr := httptest.NewRecorder()
	bulkCustomPropertiesHandler(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)

	props, ok := deviceGen.allDevices[0].CustomProperties.(map[string]interface{})
	require.True(t, ok)
	require.Equal(t, false, props["availability"])
}
