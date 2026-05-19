package agent

import (
	"context"
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
