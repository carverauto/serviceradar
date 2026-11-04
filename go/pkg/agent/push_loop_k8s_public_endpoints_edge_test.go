/*
 * Copyright 2026 Carver Automation Corporation.
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

package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	srproto "github.com/carverauto/serviceradar/proto"
)

func decodeSpooledK8sSnapshot(t *testing.T, sp *spool.Spool) (*edgev1.EdgeRecordV1, *edgev1.K8SPublicEndpointsSnapshotV1) {
	t.Helper()
	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	require.NoError(t, edgerecord.ValidateK8sPublicEndpointsRecord(records[0]))
	var snap edgev1.K8SPublicEndpointsSnapshotV1
	require.NoError(t, proto.Unmarshal(recordBody(t, records[0]), &snap))
	return records[0], &snap
}

type countingK8sEndpointsService struct {
	calls     atomic.Int32
	available bool
	payload   []byte
}

func (s *countingK8sEndpointsService) Name() string                      { return K8sPublicEndpointsServiceName }
func (s *countingK8sEndpointsService) Start(context.Context) error       { return nil }
func (s *countingK8sEndpointsService) Stop(context.Context) error        { return nil }
func (s *countingK8sEndpointsService) UpdateConfig(*models.Config) error { return nil }
func (s *countingK8sEndpointsService) StatusServiceType() string {
	return K8sPublicEndpointsServiceType
}
func (s *countingK8sEndpointsService) StatusSource() string { return K8sPublicEndpointsSourceResults }

func (s *countingK8sEndpointsService) GetStatus(_ context.Context) (*srproto.StatusResponse, error) {
	s.calls.Add(1)
	return &srproto.StatusResponse{
		Available:   s.available,
		Message:     s.payload,
		ServiceName: K8sPublicEndpointsServiceName,
		ServiceType: K8sPublicEndpointsServiceType,
	}, nil
}

type gatingEdgeAppender struct {
	allow   bool
	records []*edgev1.EdgeRecordV1
	ids     [][]byte
}

func (g *gatingEdgeAppender) AppendFlow(_ string, eventID, body []byte) (uint64, error) {
	if !g.allow {
		return 0, errors.New("spool temporarily full")
	}
	var record edgev1.EdgeRecordV1
	if err := proto.Unmarshal(body, &record); err != nil {
		return 0, err
	}
	g.records = append(g.records, &record)
	g.ids = append(g.ids, append([]byte(nil), eventID...))
	return uint64(len(g.records)), nil
}

func TestPushLoopK8sPublicEndpointsEdgeUnderGrantAndLegacySuppression(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	spoolFile := filepath.Join(dir, "public-endpoints.json")
	rawSnapshot := map[string]any{
		"cluster_id":   "cluster-alpha",
		"generated_at": "2026-07-01T12:00:00Z",
		"endpoints": []map[string]any{
			{
				"cluster_id":              "cluster-alpha",
				"ip":                      "192.0.2.10",
				"hostname":                "ingress.example.com",
				"port":                    443,
				"protocol":                "TCP",
				"exposure_class":          "LoadBalancer",
				"external_traffic_policy": "Local",
				"metallb_pool":            "public-v4",
				"load_balancer_ip_mode":   "VIP",
				"namespace":               "ingress-system",
				"service_name":            "edge-gw",
				"service_uid":             "uid-svc-1",
				"gateway_name":            "main-gw",
				"gateway_class":           "cilium",
				"listener_name":           "https",
				"route_kind":              "HTTPRoute",
				"route_name":              "app-route",
				"service_target_port":     8443,
				"service_target_name":     "https-target",
				"annotations":             map[string]any{"metallb.universe.tf/address-pool": "public-v4"},
				"observed_at":             "2026-07-01T12:00:00Z",
				"backend_refs": []map[string]any{
					{
						"group":     "",
						"kind":      "Service",
						"namespace": "app-ns",
						"name":      "app-svc",
						"port":      8080,
						"weight":    100,
					},
				},
				"endpoint_targets": []map[string]any{
					{
						"ip":            "192.0.2.50",
						"port":          8080,
						"protocol":      "TCP",
						"pod_namespace": "app-ns",
						"pod_name":      "app-pod-1",
						"node_name":     "node-1",
						"ready":         true,
					},
				},
			},
		},
		"correlation_hints": []map[string]any{
			{
				"public_ip":       "192.0.2.10",
				"public_hostname": "ingress.example.com",
				"public_port":     443,
				"protocol":        "TCP",
				"backend_ip":      "192.0.2.50",
				"backend_port":    8080,
				"pod_namespace":   "app-ns",
				"pod_name":        "app-pod-1",
				"node_name":       "node-1",
				"namespace":       "ingress-system",
				"service_name":    "edge-gw",
				"gateway_name":    "main-gw",
				"route_kind":      "HTTPRoute",
				"route_name":      "app-route",
				"exposure_class":  "LoadBalancer",
			},
		},
	}
	encoded, err := json.Marshal(rawSnapshot)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(spoolFile, encoded, 0o600))

	k8sSvc := NewK8sPublicEndpointsSpoolService(sysmonEdgeAgentID, &K8sPublicEndpointsStatusConfig{
		Enabled:   true,
		SpoolPath: spoolFile,
		ClusterID: "cluster-alpha",
	})

	sp := openTestEdgeSpool(t)
	pl := &PushLoop{
		logger: logger.NewTestLogger(),
		server: &Server{
			config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
			services: []Service{k8sSvc},
		},
	}
	pl.SetEdgeDiscoverySpool(sp)
	pl.edgeOutputGrants.replace(sysmonEdgeAgentID, []*srproto.EdgeOutputGrant{
		discoveryGrant(t, edgerecord.K8sPublicEndpointsContractID, edgerecord.K8sPublicEndpointsProjectedWriteBytesPerRecord, "serviceradar.agent.k8s"),
	}, time.Now())

	statuses, _ := pl.collectAllStatusesSeparated(context.Background())
	for _, st := range statuses {
		assert.NotEqual(t, K8sPublicEndpointsServiceType, st.GetServiceType(), "k8s_public_endpoints must not ride legacy statuses while grant is held")
	}

	record, snap := decodeSpooledK8sSnapshot(t, sp)
	assert.Equal(t, uint32(1), record.GetProjectedRowCount())
	assert.Equal(t, "cluster-alpha", snap.GetClusterId())
	assert.Equal(t, sysmonEdgeAgentID, snap.GetAgentId())
	require.Len(t, snap.GetEndpoints(), 1)
	ep := snap.GetEndpoints()[0]
	assert.Equal(t, "192.0.2.10", ep.GetIp())
	assert.Equal(t, "ingress.example.com", ep.GetHostname())
	assert.Equal(t, int32(443), ep.GetPort())
	assert.Equal(t, int32(8443), ep.GetServiceTargetPort())
	require.Len(t, ep.GetBackendRefs(), 1)
	assert.Equal(t, "app-svc", ep.GetBackendRefs()[0].GetName())
	require.Len(t, ep.GetEndpointTargets(), 1)
	assert.Equal(t, "192.0.2.50", ep.GetEndpointTargets()[0].GetIp())
	assert.True(t, ep.GetEndpointTargets()[0].GetReady())
	require.Len(t, snap.GetCorrelationHints(), 1)
	assert.Equal(t, "192.0.2.50", snap.GetCorrelationHints()[0].GetBackendIp())

	// Second collection with identical file content is deduplicated by lastSentHash.
	statuses, _ = pl.collectAllStatusesSeparated(context.Background())
	for _, st := range statuses {
		assert.NotEqual(t, K8sPublicEndpointsServiceType, st.GetServiceType())
	}
	assert.Len(t, spooledRecords(t, sp), 1)
}

func TestPushLoopK8sPublicEndpointsEdgeBackpressurePausesGetStatus(t *testing.T) {
	t.Parallel()

	payload := []byte(`{"cluster_id":"cluster-alpha","generated_at":"2026-07-01T12:00:00Z","endpoints":[{"ip":"192.0.2.10","port":443,"protocol":"TCP","namespace":"default","service_name":"svc-a"}]}`)
	svc := &countingK8sEndpointsService{
		available: true,
		payload:   payload,
	}
	appender := &gatingEdgeAppender{allow: false}

	pl := &PushLoop{
		logger:             logger.NewTestLogger(),
		edgeDiscoverySpool: appender,
		server: &Server{
			config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
			services: []Service{svc},
		},
	}
	pl.edgeOutputGrants.replace(sysmonEdgeAgentID, []*srproto.EdgeOutputGrant{
		discoveryGrant(t, edgerecord.K8sPublicEndpointsContractID, edgerecord.K8sPublicEndpointsProjectedWriteBytesPerRecord, "serviceradar.agent.k8s"),
	}, time.Now())

	// First cycle: GetStatus is called once; spool refuses, so item is held in k8sPublicEndpointsEdge.built.
	statuses, _ := pl.collectAllStatusesSeparated(context.Background())
	for _, st := range statuses {
		assert.NotEqual(t, K8sPublicEndpointsServiceType, st.GetServiceType())
	}
	assert.Equal(t, int32(1), svc.calls.Load())
	require.NotNil(t, pl.k8sPublicEndpointsEdge.built)
	firstEventID := append([]byte(nil), pl.k8sPublicEndpointsEdge.built.record.GetEventId()...)

	// Second cycle while spool still refuses: GetStatus must NOT be called (paused).
	statuses, _ = pl.collectAllStatusesSeparated(context.Background())
	for _, st := range statuses {
		assert.NotEqual(t, K8sPublicEndpointsServiceType, st.GetServiceType())
	}
	assert.Equal(t, int32(1), svc.calls.Load(), "GetStatus must not be called while pending item is unadmitted")
	require.NotNil(t, pl.k8sPublicEndpointsEdge.built)

	// Third cycle: spool admits the pending item under its original event_id, then polls GetStatus.
	appender.allow = true
	_, _ = pl.collectAllStatusesSeparated(context.Background())
	assert.Nil(t, pl.k8sPublicEndpointsEdge.built)
	require.Len(t, appender.ids, 1)
	assert.True(t, bytes.Equal(firstEventID, appender.ids[0]), "retried record must preserve its original event_id")
	assert.Equal(t, int32(2), svc.calls.Load())
}

func TestPushLoopK8sPublicEndpointsLegacyWithoutGrant(t *testing.T) {
	t.Parallel()

	payload := []byte(`{"cluster_id":"cluster-alpha","generated_at":"2026-07-01T12:00:00Z","endpoints":[]}`)
	svc := &countingK8sEndpointsService{
		available: true,
		payload:   payload,
	}
	sp := openTestEdgeSpool(t)
	pl := &PushLoop{
		logger: logger.NewTestLogger(),
		server: &Server{
			config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
			services: []Service{svc},
		},
	}
	pl.SetEdgeDiscoverySpool(sp)

	statuses, _ := pl.collectAllStatusesSeparated(context.Background())
	var found *srproto.GatewayServiceStatus
	for _, st := range statuses {
		if st.GetServiceType() == K8sPublicEndpointsServiceType {
			found = st
			break
		}
	}
	require.NotNil(t, found, "without grant, k8s_public_endpoints must remain on legacy statuses")
	assert.Equal(t, K8sPublicEndpointsServiceName, found.GetServiceName())
	assert.Equal(t, K8sPublicEndpointsSourceResults, found.GetSource())
	assert.Empty(t, spooledRecords(t, sp))
}
