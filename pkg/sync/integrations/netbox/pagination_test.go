package netbox

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const netboxDevicesPath = "/api/dcim/devices/"

func TestNetboxIntegration_Fetch_FollowsPagination(t *testing.T) {
	t.Parallel()

	var mu sync.Mutex
	requestedOffsets := make(map[string]bool)

	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != netboxDevicesPath {
			http.NotFound(w, r)
			return
		}
		if r.Header.Get("Authorization") != "Token test-token" {
			http.Error(w, "missing/invalid auth", http.StatusUnauthorized)
			return
		}

		offset := r.URL.Query().Get("offset")
		if offset == "" {
			offset = "0"
		}

		mu.Lock()
		requestedOffsets[offset] = true
		mu.Unlock()

		switch offset {
		case "0":
			results := make([]any, 0, 50)
			for id := 1; id <= 50; id++ {
				results = append(results, netboxDeviceJSON(id))
			}

			resp := map[string]any{
				"count":    75,
				"next":     fmt.Sprintf("%s/api/dcim/devices/?offset=50", server.URL),
				"previous": nil,
				"results":  results,
			}
			_ = json.NewEncoder(w).Encode(resp)
		case "50":
			results := make([]any, 0, 25)
			for id := 51; id <= 75; id++ {
				results = append(results, netboxDeviceJSON(id))
			}

			resp := map[string]any{
				"count":    75,
				"next":     nil,
				"previous": fmt.Sprintf("%s/api/dcim/devices/?offset=0", server.URL),
				"results":  results,
			}
			_ = json.NewEncoder(w).Encode(resp)
		default:
			http.Error(w, "unexpected offset", http.StatusBadRequest)
		}
	}))
	t.Cleanup(server.Close)

	integ := &NetboxIntegration{
		Config: &models.SourceConfig{
			Endpoint:           server.URL,
			InsecureSkipVerify: true,
			Credentials:        map[string]string{"api_token": "test-token"},
			AgentID:            "agent",
			PollerID:           "poller",
			Partition:          "partition",
		},
		Logger: logger.NewTestLogger(),
	}

	events, err := integ.Fetch(context.Background())
	require.NoError(t, err)
	require.Len(t, events, 75)

	mu.Lock()
	require.True(t, requestedOffsets["0"])
	require.True(t, requestedOffsets["50"])
	mu.Unlock()
}

func TestNetboxIntegration_Reconcile_DoesNotRetractPaginatedDevices(t *testing.T) {
	t.Parallel()

	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != netboxDevicesPath {
			http.NotFound(w, r)
			return
		}

		offset := r.URL.Query().Get("offset")
		if offset == "" {
			offset = "0"
		}

		switch offset {
		case "0":
			resp := map[string]any{
				"count":    2,
				"next":     fmt.Sprintf("%s/api/dcim/devices/?offset=1", server.URL),
				"previous": nil,
				"results":  []any{netboxDeviceJSON(1)},
			}
			_ = json.NewEncoder(w).Encode(resp)
		case "1":
			resp := map[string]any{
				"count":    2,
				"next":     nil,
				"previous": fmt.Sprintf("%s/api/dcim/devices/?offset=0", server.URL),
				"results":  []any{netboxDeviceJSON(2)},
			}
			_ = json.NewEncoder(w).Encode(resp)
		default:
			http.Error(w, "unexpected offset", http.StatusBadRequest)
		}
	}))
	t.Cleanup(server.Close)

	ctrl := gomock.NewController(t)
	t.Cleanup(ctrl.Finish)

	mockQuerier := NewMockSRQLQuerier(ctrl)
	mockSubmitter := NewMockResultSubmitter(ctrl)
	mockSubmitter.EXPECT().SubmitBatchSweepResults(gomock.Any(), gomock.Any()).Times(0)

	mockQuerier.
		EXPECT().
		GetDeviceStatesBySource(gomock.Any(), "netbox").
		Return([]DeviceState{
			{
				DeviceID: "partition:10.0.0.1",
				IP:       "10.0.0.1",
				Metadata: map[string]interface{}{"integration_id": "1"},
			},
			{
				DeviceID: "partition:10.0.0.2",
				IP:       "10.0.0.2",
				Metadata: map[string]interface{}{"integration_id": "2"},
			},
		}, nil)

	integ := &NetboxIntegration{
		Config: &models.SourceConfig{
			Endpoint:           server.URL,
			InsecureSkipVerify: true,
			Credentials:        map[string]string{"api_token": "test-token"},
			AgentID:            "agent",
			PollerID:           "poller",
			Partition:          "partition",
		},
		Querier:         mockQuerier,
		ResultSubmitter: mockSubmitter,
		Logger:          logger.NewTestLogger(),
	}

	require.NoError(t, integ.Reconcile(context.Background()))
}

func TestNetboxIntegration_Fetch_ReturnsErrorOnPaginationFailure(t *testing.T) {
	t.Parallel()

	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != netboxDevicesPath {
			http.NotFound(w, r)
			return
		}

		offset := r.URL.Query().Get("offset")
		if offset == "" {
			offset = "0"
		}

		switch offset {
		case "0":
			resp := map[string]any{
				"count":    2,
				"next":     fmt.Sprintf("%s/api/dcim/devices/?offset=1", server.URL),
				"previous": nil,
				"results":  []any{netboxDeviceJSON(1)},
			}
			_ = json.NewEncoder(w).Encode(resp)
		case "1":
			http.Error(w, "boom", http.StatusInternalServerError)
		default:
			http.Error(w, "unexpected offset", http.StatusBadRequest)
		}
	}))
	t.Cleanup(server.Close)

	integ := &NetboxIntegration{
		Config: &models.SourceConfig{
			Endpoint:           server.URL,
			InsecureSkipVerify: true,
			Credentials:        map[string]string{"api_token": "test-token"},
			AgentID:            "agent",
			PollerID:           "poller",
			Partition:          "partition",
		},
		Logger: logger.NewTestLogger(),
	}

	events, err := integ.Fetch(context.Background())
	require.Error(t, err)
	require.Nil(t, events)
}

func netboxDeviceJSON(id int) map[string]any {
	return map[string]any{
		"id":   id,
		"name": fmt.Sprintf("device-%d", id),
		"role": map[string]any{"id": 1, "name": "role"},
		"site": map[string]any{"id": 1, "name": "site"},
		"primary_ip4": map[string]any{
			"id":      id,
			"address": fmt.Sprintf("10.0.0.%d/32", id),
		},
	}
}
