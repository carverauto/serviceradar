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
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func workloadIdentityGrant(t *testing.T, maxRows uint32) *proto.EdgeOutputGrant {
	t.Helper()
	return currentRowBoundedGrant(t, rowBoundedGrantSpec{
		contractID:       edgerecord.WorkloadIdentityContractID,
		contractVersion:  edgerecord.WorkloadIdentityContractVersion,
		packageID:        "serviceradar.agent.workload_identity",
		digestSeed:       "synthetic-workload-identity-contract",
		maxRows:          maxRows,
		writeBytesPerRow: edgerecord.WorkloadIdentityProjectedWriteBytesPerRecord,
	})
}

func newWorkloadIdentityTestLoop(t *testing.T, sp *RecordSpool, grants ...*proto.EdgeOutputGrant) (*PushLoop, string) {
	t.Helper()
	configDir := t.TempDir()
	srv := &Server{
		configDir: configDir,
		config: &ServerConfig{
			AgentID:   sysmonEdgeAgentID,
			Partition: "default",
			HostIP:    "192.0.2.10",
		},
		logger: logger.NewTestLogger(),
	}
	loop := &PushLoop{
		server: srv,
		logger: logger.NewTestLogger(),
	}
	loop.SetEdgeDiscoverySpool(sp)
	if len(grants) > 0 {
		installTestEdgeGrants(t, loop, sysmonEdgeAgentID, grants, time.Now())
	}
	return loop, configDir
}

func writeWorkloadIdentityTestSnapshot(t *testing.T, configDir, content string) {
	t.Helper()
	dir := filepath.Join(configDir, "workload-identity", "spool")
	require.NoError(t, os.MkdirAll(dir, 0o755))
	path := filepath.Join(dir, "latest.json")
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	overrideFile := filepath.Join(configDir, "workload-identity-snapshot.path")
	require.NoError(t, os.WriteFile(overrideFile, []byte(path+"\n"), 0o600))
}

func TestWorkloadIdentityWithAGrantGoesOnlyToTheEdgeSpool(t *testing.T) {
	sp := openTestEdgeSpool(t)
	grant := workloadIdentityGrant(t, 10_000)
	loop, configDir := newWorkloadIdentityTestLoop(t, sp, grant)

	writeWorkloadIdentityTestSnapshot(t, configDir, `{
		"observed_at_unix_nano": 1780000000000000000,
		"enabled": true,
		"endpoint": {
			"type": "Cri",
			"endpoint": {
				"path": "/run/containerd/containerd.sock",
				"source": {"ConfigFile": "/etc/crictl.yaml"}
			}
		},
		"count": 2,
		"context_name": "example-ctx",
		"cluster_id": "cluster-01",
		"cluster_name": "example-cluster",
		"identities": [
			{
				"container_id": "container-alpha",
				"identity": {
					"pod_sandbox_id": "sandbox-alpha",
					"pod_name": "checkout-api-0",
					"pod_namespace": "payments",
					"pod_uid": "pod-uid-alpha",
					"container_id": "container-alpha",
					"container_name": "checkout-api",
					"image": "registry.example.com/checkout-api:1.2.3",
					"image_ref": "registry.example.com/checkout-api@sha256:1111",
					"runtime_pid": 4312,
					"cgroup_path": "/kubepods.slice/alpha.scope",
					"labels": {"app.kubernetes.io/name": "checkout-api"},
					"annotations": {"io.kubernetes.container.restartCount": "0"},
					"runtime_source": "Containerd",
					"confidence": "High",
					"degradation_reason": null
				}
			},
			{
				"container_id": "container-beta",
				"identity": {
					"pod_name": "worker-0",
					"pod_namespace": "jobs",
					"container_id": "container-beta",
					"container_name": "worker",
					"runtime_pid": null,
					"runtime_source": "Containerd",
					"confidence": "Medium",
					"degradation_reason": "runtime pid missing"
				}
			}
		]
	}`)

	require.True(t, loop.pushWorkloadIdentity())

	// Unchanged snapshot signature is not re-spooled on the next tick.
	require.False(t, loop.pushWorkloadIdentity())

	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	require.NoError(t, edgerecord.ValidateWorkloadIdentityRecord(records[0]))
	require.Equal(t, uint32(2), records[0].GetProjectedRowCount())
	require.Equal(t, uint64(2*edgerecord.WorkloadIdentityProjectedWriteBytesPerRecord), records[0].GetProjectedWriteBytes())

	snap := &edgev1.WorkloadIdentitySnapshotV1{}
	require.NoError(t, (gproto.UnmarshalOptions{DiscardUnknown: false}).Unmarshal(recordBody(t, records[0]), snap))
	require.True(t, snap.GetEnabled())
	require.Equal(t, int64(1780000000000000000), snap.GetObservedAtUnixNano())
	require.Equal(t, "Cri", snap.GetEndpoint().GetType())
	require.Equal(t, "/run/containerd/containerd.sock", snap.GetEndpoint().GetPath())
	require.Equal(t, "ConfigFile", snap.GetEndpoint().GetSource())
	require.Equal(t, "/etc/crictl.yaml", snap.GetEndpoint().GetConfigFilePath())
	require.Equal(t, "example-ctx", snap.GetContextName())
	require.Equal(t, "cluster-01", snap.GetClusterId())
	require.Equal(t, "example-cluster", snap.GetClusterName())
	require.Len(t, snap.GetIdentities(), 2)

	alpha := snap.GetIdentities()[0].GetIdentity()
	require.Equal(t, "container-alpha", alpha.GetContainerId())
	require.Equal(t, "checkout-api-0", alpha.GetPodName())
	require.True(t, alpha.GetHasRuntimePid())
	require.Equal(t, uint32(4312), alpha.GetRuntimePid())
	require.Equal(t, "checkout-api", alpha.GetLabels()["app.kubernetes.io/name"])

	beta := snap.GetIdentities()[1].GetIdentity()
	require.Equal(t, "container-beta", beta.GetContainerId())
	require.False(t, beta.GetHasRuntimePid())
	require.Equal(t, "runtime pid missing", beta.GetDegradationReason())
}

func TestWorkloadIdentityEmptyDisabledSnapshotEmitsOneRowRecord(t *testing.T) {
	sp := openTestEdgeSpool(t)
	grant := workloadIdentityGrant(t, 10_000)
	loop, configDir := newWorkloadIdentityTestLoop(t, sp, grant)

	writeWorkloadIdentityTestSnapshot(t, configDir, `{
		"observed_at_unix_nano": 1780000000000000000,
		"enabled": false,
		"endpoint": null,
		"count": 0,
		"identities": [],
		"degradation_reason": "workload identity collection disabled"
	}`)

	require.True(t, loop.pushWorkloadIdentity())

	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	require.NoError(t, edgerecord.ValidateWorkloadIdentityRecord(records[0]))
	require.Equal(t, uint32(1), records[0].GetProjectedRowCount())
	require.Equal(t, uint64(edgerecord.WorkloadIdentityProjectedWriteBytesPerRecord), records[0].GetProjectedWriteBytes())
}

// Without a grant the snapshot file is not read or committed: it waits on disk,
// counted as a grant hold, and spools once the grant is held.
func TestWorkloadIdentityWithoutGrantLeavesTheSnapshotOnDisk(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, configDir := newWorkloadIdentityTestLoop(t, sp)

	writeWorkloadIdentityTestSnapshot(t, configDir, `{
		"observed_at_unix_nano": 1780000000000000000,
		"enabled": true,
		"count": 1,
		"identities": [{"container_id": "container-held", "identity": {"container_id": "container-held"}}]
	}`)

	require.False(t, loop.pushWorkloadIdentity())
	require.Empty(t, spooledRecords(t, sp))
	require.True(t, loop.lastWorkloadIdentityFile.zero(), "an unsent snapshot must not be committed")
	var metrics strings.Builder
	require.NoError(t, loop.server.edgeProducerDrops.write(&metrics))
	require.Contains(t, metrics.String(), `agent_edge_record_grant_holds_total{producer="workload_identity"} 1`)

	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{workloadIdentityGrant(t, 10_000)}, time.Now())
	require.True(t, loop.pushWorkloadIdentity())
	require.Len(t, spooledRecords(t, sp), 1)
}

func TestWorkloadIdentityPausedSpoolHoldsOneSnapshotWithoutReadingNewerFile(t *testing.T) {
	paused := refusingEdgeSpool(t)
	grant := workloadIdentityGrant(t, 10_000)
	loop, configDir := newWorkloadIdentityTestLoop(t, paused, grant)

	writeWorkloadIdentityTestSnapshot(t, configDir, `{
		"observed_at_unix_nano": 1780000000000000000,
		"enabled": true,
		"count": 1,
		"identities": [{"container_id": "container-first", "identity": {"container_id": "container-first"}}]
	}`)

	require.False(t, loop.pushWorkloadIdentity())
	require.NotNil(t, loop.workloadIdentityEdge.built)
	firstEventID := append([]byte(nil), loop.workloadIdentityEdge.built.records[0].GetEventId()...)

	// Overwrite the on-disk snapshot while the first snapshot is still undelivered.
	writeWorkloadIdentityTestSnapshot(t, configDir, `{
		"observed_at_unix_nano": 1780000001000000000,
		"enabled": true,
		"count": 1,
		"identities": [{"container_id": "container-second", "identity": {"container_id": "container-second"}}]
	}`)

	require.False(t, loop.pushWorkloadIdentity())
	require.Zero(t, edgeDrops(loop, edgeProducerWorkloadIdentity, edgeDropRetryBufferFull))
	require.Equal(t, firstEventID, loop.workloadIdentityEdge.built.records[0].GetEventId(),
		"pending snapshot must keep its original event ID and pause reading the newer file")

	// Unblock the spool with the grant withdrawn: the built snapshot still
	// finishes under the grant it was built with, but the newer file is not
	// read until a grant is held again.
	accepting := openTestEdgeSpool(t)
	loop.SetEdgeDiscoverySpool(accepting)
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, nil, time.Now())

	require.True(t, loop.pushWorkloadIdentity())
	records := spooledRecords(t, accepting)
	require.Len(t, records, 1)
	require.Equal(t, firstEventID, records[0].GetEventId())

	require.False(t, loop.pushWorkloadIdentity())
	require.Len(t, spooledRecords(t, accepting), 1)

	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{grant}, time.Now())
	require.True(t, loop.pushWorkloadIdentity())
	records = spooledRecords(t, accepting)
	require.Len(t, records, 2)
}

func TestWorkloadIdentitySplitsAcrossMultipleRecordsWhenExceedingRowLimit(t *testing.T) {
	sp := openTestEdgeSpool(t)
	grant := workloadIdentityGrant(t, 1)
	loop, configDir := newWorkloadIdentityTestLoop(t, sp, grant)

	writeWorkloadIdentityTestSnapshot(t, configDir, `{
		"observed_at_unix_nano": 1780000000000000000,
		"enabled": true,
		"count": 2,
		"cluster_name": "example-cluster",
		"identities": [
			{"container_id": "container-1", "identity": {"container_id": "container-1", "pod_name": "pod-1"}},
			{"container_id": "container-2", "identity": {"container_id": "container-2", "pod_name": "pod-2"}}
		]
	}`)

	require.True(t, loop.pushWorkloadIdentity())

	records := spooledRecords(t, sp)
	require.Len(t, records, 2)
	for i, rec := range records {
		require.NoError(t, edgerecord.ValidateWorkloadIdentityRecord(rec), "part %d", i)
		require.Equal(t, uint32(1), rec.GetProjectedRowCount())
	}
}

func TestWorkloadIdentityInvalidSnapshotRecordsInvalidRecordDrop(t *testing.T) {
	sp := openTestEdgeSpool(t)
	grant := workloadIdentityGrant(t, 10_000)
	loop, configDir := newWorkloadIdentityTestLoop(t, sp, grant)

	writeWorkloadIdentityTestSnapshot(t, configDir, `{
		"observed_at_unix_nano": 1780000000000000000,
		"enabled": true,
		"count": 1,
		"identities": [{"identity": {"pod_name": "missing-container-id"}}]
	}`)

	require.False(t, loop.pushWorkloadIdentity())
	require.Equal(t, uint64(1), edgeDrops(loop, edgeProducerWorkloadIdentity, edgeDropInvalidRecord))
	require.Empty(t, spooledRecords(t, sp))
}
