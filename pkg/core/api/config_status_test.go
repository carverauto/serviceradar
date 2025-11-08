package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
)

func TestHandleConfigStatusReportsMissingKeys(t *testing.T) {
	server := &APIServer{
		logger: logger.NewTestLogger(),
	}

	server.kvGetFn = func(ctx context.Context, key string) ([]byte, bool, uint64, error) {
		if key == "config/core.json" {
			return nil, false, 0, nil
		}
		return []byte("{}"), true, 1, nil
	}

	req := httptest.NewRequest(http.MethodGet, "/api/admin/config/status", nil)
	rr := httptest.NewRecorder()

	server.handleConfigStatus(rr, req)

	require.Equal(t, http.StatusServiceUnavailable, rr.Code)

	var resp configStatusResponse
	require.NoError(t, json.NewDecoder(rr.Body).Decode(&resp))
	require.Equal(t, "missing", resp.Status)
	require.Equal(t, 1, resp.MissingCount)
	require.NotNil(t, resp.FirstMissing)
	require.Equal(t, "core", resp.FirstMissing.Name)
}

func TestQualifyKVKeyPrefixesDomains(t *testing.T) {
	server := &APIServer{
		kvEndpoints: map[string]*KVEndpoint{
			"leaf-1": {
				ID:     "leaf-1",
				Domain: "leaf-a",
			},
		},
	}

	require.Equal(t,
		"domains/leaf-a/config/core.json",
		server.qualifyKVKey("leaf-1", "config/core.json"),
	)

	require.Equal(t,
		"domains/leaf-a/config/core.json",
		server.qualifyKVKey("leaf-1", "domains/leaf-a/config/core.json"),
	)

	require.Equal(t,
		"config/core.json",
		server.qualifyKVKey("", "config/core.json"),
	)
}

func TestServiceTemplatesCoverDescriptors(t *testing.T) {
	for _, desc := range config.ServiceDescriptors() {
		tmpl, ok := serviceTemplates[desc.Name]
		require.Truef(t, ok, "missing template for descriptor %s", desc.Name)
		require.NotEmptyf(t, tmpl.data, "empty template for descriptor %s", desc.Name)
		require.Equalf(t, desc.Format, tmpl.format, "format mismatch for descriptor %s", desc.Name)
	}
}
