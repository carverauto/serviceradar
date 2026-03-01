package agent

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

type fakeSweeperService struct {
	summary *models.SweepSummary
}

func (*fakeSweeperService) Start(context.Context) error                    { return nil }
func (*fakeSweeperService) Stop() error                                    { return nil }
func (f *fakeSweeperService) GetStatus(context.Context) (*models.SweepSummary, error) {
	return f.summary, nil
}
func (*fakeSweeperService) UpdateConfig(*models.Config) error          { return nil }
func (*fakeSweeperService) GetScannerStats() *models.ScannerStats      { return nil }

func TestSweepResultsIncludeSweepGroupIDFromConfigWhenExecutionContextEmpty(t *testing.T) {
	now := time.Now().UTC()
	lastSweep := now.Unix()

	summary := &models.SweepSummary{
		Network:        "10.0.0.0/24",
		TotalHosts:     1,
		AvailableHosts: 1,
		LastSweep:      lastSweep,
		Ports:          nil,
		Hosts: []models.HostResult{
			{
				Host:      "10.0.0.10",
				Available: true,
				FirstSeen: now.Add(-time.Minute),
				LastSeen:  now,
			},
		},
	}

	svc := &SweepService{
		sweeper: &fakeSweeperService{summary: summary},
		config: &models.Config{
			SweepGroupID: "group-1",
			ConfigHash:   "hash-1",
		},
		stats:  newScanStats(),
		logger: logger.NewTestLogger(),

		// Simulate the pre-fix behavior: execution context wasn't seeded.
		sweepGroupID: "",
	}

	resp, err := svc.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.True(t, resp.HasNewData)
	require.Equal(t, "group-1", resp.SweepGroupId)

	var payload map[string]any
	require.NoError(t, json.Unmarshal(resp.Data, &payload))
	require.Equal(t, "group-1", payload["sweep_group_id"])
}

