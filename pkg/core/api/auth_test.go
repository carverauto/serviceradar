package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gorilla/mux"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
)

func TestHandleGetConfigSeedsFromTemplate(t *testing.T) {
	testPayload := []byte(`{"seeded":true}`)
	store := make(map[string][]byte)
	store["templates/core.json"] = append([]byte(nil), testPayload...)

	server := &APIServer{
		logger: logger.NewTestLogger(),
	}

	server.kvGetFn = func(ctx context.Context, key string) ([]byte, bool, uint64, error) {
		value, ok := store[key]
		return value, ok, 1, nil
	}

	server.kvPutFn = func(ctx context.Context, key string, value []byte, ttl int64) error {
		store[key] = append([]byte(nil), value...)
		return nil
	}

	req := httptest.NewRequest(http.MethodGet, "/api/admin/config/core", nil)
	req = mux.SetURLVars(req, map[string]string{"service": "core"})
	rr := httptest.NewRecorder()

	server.handleGetConfig(rr, req)

	require.Equal(t, 200, rr.Code)
	require.Equal(t, "application/json", rr.Header().Get("Content-Type"))
	var resp configResponse
	require.NoError(t, json.Unmarshal(rr.Body.Bytes(), &resp))
	require.Equal(t, "config/core.json", resp.Metadata.KVKey)
	require.Equal(t, configOriginSeeded, resp.Metadata.Origin)
	require.Equal(t, "system", resp.Metadata.LastWriter)
	require.Equal(t, config.ConfigFormatJSON, resp.Metadata.Format)
	require.JSONEq(t, string(testPayload), string(resp.Config))

	configValue, ok := store["config/core.json"]
	require.True(t, ok)
	require.Equal(t, string(testPayload), string(configValue))

	metaValue, ok := store["config/core.json.meta"]
	require.True(t, ok)
	var record configMetadataRecord
	require.NoError(t, json.Unmarshal(metaValue, &record))
	require.Equal(t, configOriginSeeded, record.Origin)
}

func TestHandleGetConfigAgentRequiresAgentID(t *testing.T) {
	server := &APIServer{
		logger: logger.NewTestLogger(),
	}

	req := httptest.NewRequest(http.MethodGet, "/api/admin/config/snmp", nil)
	req = mux.SetURLVars(req, map[string]string{"service": "snmp"})
	rr := httptest.NewRecorder()

	server.handleGetConfig(rr, req)

	require.Equal(t, http.StatusBadRequest, rr.Code)
}

func TestHandleGetConfigAgentDescriptorSeedsTemplate(t *testing.T) {
	server := &APIServer{
		logger: logger.NewTestLogger(),
	}

	stored := make(map[string][]byte)
	stored["templates/agent-snmp.json"] = []byte(`{"defaults":true}`)

	server.kvGetFn = func(ctx context.Context, key string) ([]byte, bool, uint64, error) {
		value, ok := stored[key]
		return value, ok, 1, nil
	}

	server.kvPutFn = func(ctx context.Context, key string, value []byte, ttl int64) error {
		stored[key] = append([]byte(nil), value...)
		return nil
	}

	req := httptest.NewRequest(http.MethodGet, "/api/admin/config/snmp?agent_id=test-agent", nil)
	req = mux.SetURLVars(req, map[string]string{"service": "snmp"})
	rr := httptest.NewRecorder()

	server.handleGetConfig(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)
	var resp configResponse
	require.NoError(t, json.Unmarshal(rr.Body.Bytes(), &resp))
	require.Equal(t, "agents/test-agent/checkers/snmp/snmp.json", resp.Metadata.KVKey)
	require.Equal(t, configOriginSeeded, resp.Metadata.Origin)
	require.Equal(t, "system", resp.Metadata.LastWriter)
	require.NotEmpty(t, stored["agents/test-agent/checkers/snmp/snmp.json"])
}

func TestHandleConfigWatchers(t *testing.T) {
	config.ResetWatchersForTest()
	config.RegisterWatcher(config.WatcherRegistration{
		Service: "core",
		Scope:   config.ConfigScopeGlobal,
		KVKey:   "config/core.json",
	})

	server := &APIServer{logger: logger.NewTestLogger()}
	req := httptest.NewRequest(http.MethodGet, "/api/admin/config/watchers", nil)
	rr := httptest.NewRecorder()

	server.handleConfigWatchers(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)
	var resp []config.WatcherInfo
	require.NoError(t, json.NewDecoder(rr.Body).Decode(&resp))
	require.Len(t, resp, 1)
	require.Equal(t, "core", resp[0].Service)
}
