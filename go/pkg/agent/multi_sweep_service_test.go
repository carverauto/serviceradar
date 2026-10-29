package agent

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestMultiSweepServiceDoesNotAckResultsBeforeSuccessfulStream(t *testing.T) {
	now := time.Now().Unix()
	svc := &SweepService{
		sweeper: &mockSweeper{
			summary: &models.SweepSummary{
				Network:        "10.0.0.0/24",
				TotalHosts:     1,
				AvailableHosts: 1,
				LastSweep:      now,
				Hosts: []models.HostResult{
					{Host: "10.0.0.10", Available: true},
				},
			},
		},
		config:       &models.Config{SweepGroupID: "group-1"},
		stats:        newScanStats(),
		logger:       createTestLogger(),
		sweepGroupID: "group-1",
	}

	multi := &MultiSweepService{
		groups:         map[string]*SweepService{"group-1": svc},
		groupSequences: map[string]string{"group-1": ""},
		groupOrder:     []string{"group-1"},
		logger:         createTestLogger(),
	}

	ctx := context.Background()

	first, err := multi.GetSweepResults(ctx, "")
	require.NoError(t, err)
	require.True(t, first.HasNewData)
	require.Equal(t, "group-1", first.SweepGroupId)
	require.Equal(t, "1", first.CurrentSequence)

	retry, err := multi.GetSweepResults(ctx, "")
	require.NoError(t, err)
	require.True(t, retry.HasNewData, "unacknowledged results must be retried")
	require.Equal(t, first.CurrentSequence, retry.CurrentSequence)

	multi.AcknowledgeSweepResults(first.SweepGroupId, first.CurrentSequence)

	acked, err := multi.GetSweepResults(ctx, "")
	require.NoError(t, err)
	require.False(t, acked.HasNewData)
}

func TestSweepResultsStreamTimeoutScalesWithChunkCount(t *testing.T) {
	require.Equal(t, minSweepResultsStreamTimeout, sweepResultsStreamTimeout(0))
	require.Equal(t, 40*time.Second, sweepResultsStreamTimeout(10))
	require.Equal(t, maxSweepResultsStreamTimeout, sweepResultsStreamTimeout(10_000))
}

func TestCronGroupRemainsManualAcrossLeaseAndConfigChanges(t *testing.T) {
	group := SweepGroupConfig{SweepGroupID: "cron-group", ScheduleType: "cron", Networks: []string{"192.0.2.0/30"}}
	service, err := NewMultiSweepService(&ServerConfig{AgentID: "synthetic-agent"}, []SweepGroupConfig{group}, createTestLogger())
	require.NoError(t, err)
	require.Contains(t, service.groups, group.SweepGroupID)
	manual := service.groups[group.SweepGroupID].sweeper.(interface{ ManualSchedule() bool })
	require.True(t, manual.ManualSchedule())

	service.SetGroupLeaseDriven(group.SweepGroupID, true)
	service.SetGroupLeaseState(group.SweepGroupID, "active", 42, 3)
	require.True(t, manual.ManualSchedule())
	assertCronLeaseReport(t, service, "active", 42, 3)

	service.SetGroupLeaseDriven(group.SweepGroupID, false)
	require.True(t, manual.ManualSchedule())
	assertCronLeaseReportAbsent(t, service)

	require.NoError(t, service.UpdateSweepGroups(&SweepGroupsConfig{Groups: []SweepGroupConfig{group}}))
	require.True(t, manual.ManualSchedule())
	assertCronLeaseReportAbsent(t, service)
}

func assertCronLeaseReport(t *testing.T, service *MultiSweepService, state string, nextSlot int64, remaining int) {
	t.Helper()

	status, payload, err := service.GetStatusWithMetricPayload(context.Background())
	require.NoError(t, err)
	typed, ok := payload["sweep_lease"].(map[string]any)
	require.True(t, ok, "typed status missing sweep_lease: %#v", payload)
	require.Equal(t, state, typed["state"])
	require.Equal(t, nextSlot, typed["next_slot_unix_nano"])
	require.Equal(t, remaining, typed["slots_remaining"])

	var doc map[string]any
	require.NoError(t, json.Unmarshal(status.Message, &doc))
	raw, ok := doc["sweep_lease"].([]any)
	require.True(t, ok, "serialized status sweep_lease = %#v", doc["sweep_lease"])
	require.Len(t, raw, 1)
	serialized, ok := raw[0].(map[string]any)
	require.True(t, ok)
	require.Equal(t, state, serialized["state"])
	require.Equal(t, float64(nextSlot), serialized["next_slot_unix_nano"])
	require.Equal(t, float64(remaining), serialized["slots_remaining"])
}

func assertCronLeaseReportAbsent(t *testing.T, service *MultiSweepService) {
	t.Helper()

	status, payload, err := service.GetStatusWithMetricPayload(context.Background())
	require.NoError(t, err)
	_, present := payload["sweep_lease"]
	require.False(t, present, "typed status still reports sweep_lease: %#v", payload["sweep_lease"])

	var doc map[string]any
	require.NoError(t, json.Unmarshal(status.Message, &doc))
	_, present = doc["sweep_lease"]
	require.False(t, present, "serialized status still reports sweep_lease: %#v", doc["sweep_lease"])
}
