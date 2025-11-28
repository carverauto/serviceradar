package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

const coreConfigKey = "config/core.json"

func TestHandleGetIdentityConfigReadsFromCoreConfig(t *testing.T) {
	server := &APIServer{
		identityConfig: &models.IdentityReconciliationConfig{
			Enabled: false,
		},
	}

	coreConfig := map[string]interface{}{
		"listen_addr": ":8080",
		"identity_reconciliation": map[string]interface{}{
			"enabled": true,
			"promotion": map[string]interface{}{
				"enabled":         true,
				"shadow_mode":     false,
				"min_persistence": "1h",
			},
		},
	}
	payload, err := json.Marshal(coreConfig)
	require.NoError(t, err)

	server.kvGetFn = func(ctx context.Context, key string) ([]byte, bool, uint64, error) {
		if key == coreConfigKey {
			return payload, true, 3, nil
		}
		return nil, false, 0, nil
	}

	req := httptest.NewRequest(http.MethodGet, "/api/identity/config", nil)
	rr := httptest.NewRecorder()

	server.handleGetIdentityConfig(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)

	var resp struct {
		Identity *models.IdentityReconciliationConfig `json:"identity"`
		Revision uint64                               `json:"revision"`
	}
	require.NoError(t, json.NewDecoder(rr.Body).Decode(&resp))
	require.NotNil(t, resp.Identity)
	require.True(t, resp.Identity.Enabled)
	require.NotNil(t, resp.Identity.Promotion)
	require.True(t, resp.Identity.Promotion.Enabled)
	require.Equal(t, uint64(3), resp.Revision)
}

func TestHandleUpdateIdentityConfigMergesAndPersists(t *testing.T) {
	server := &APIServer{}

	baseConfig := map[string]interface{}{
		"listen_addr": ":8080",
		"identity_reconciliation": map[string]interface{}{
			"enabled": false,
			"promotion": map[string]interface{}{
				"enabled":         false,
				"min_persistence": "24h",
			},
		},
	}
	payload, err := json.Marshal(baseConfig)
	require.NoError(t, err)

	server.kvGetFn = func(ctx context.Context, key string) ([]byte, bool, uint64, error) {
		if key == coreConfigKey {
			return payload, true, 2, nil
		}
		return nil, false, 0, nil
	}

	var saved map[string]interface{}
	var putKeys []string
	server.kvPutFn = func(ctx context.Context, key string, value []byte, _ int64) error {
		putKeys = append(putKeys, key)
		if key == coreConfigKey {
			require.NoError(t, json.Unmarshal(value, &saved))
		}
		return nil
	}

	body := bytes.NewBufferString(`{"identity":{"enabled":true,"promotion":{"enabled":true,"min_persistence":"12h"},"drift":{"baseline_devices":50000,"tolerance_percent":2}}}`)
	req := httptest.NewRequest(http.MethodPut, "/api/identity/config", body)
	rr := httptest.NewRecorder()

	server.handleUpdateIdentityConfig(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)
	require.Contains(t, putKeys, "config/core.json")
	require.Contains(t, putKeys, "config/core.json.meta")

	identityRaw, ok := saved["identity_reconciliation"].(map[string]interface{})
	require.True(t, ok)
	require.Equal(t, true, identityRaw["enabled"])

	promoRaw, ok := identityRaw["promotion"].(map[string]interface{})
	require.True(t, ok)
	require.Equal(t, true, promoRaw["enabled"])
	persistence, ok := promoRaw["min_persistence"].(string)
	require.True(t, ok)
	duration, err := time.ParseDuration(persistence)
	require.NoError(t, err)
	require.Equal(t, 12*time.Hour, duration)

	driftRaw, ok := identityRaw["drift"].(map[string]interface{})
	require.True(t, ok)
	require.EqualValues(t, 50000, driftRaw["baseline_devices"])
	require.EqualValues(t, 2, driftRaw["tolerance_percent"])
}
