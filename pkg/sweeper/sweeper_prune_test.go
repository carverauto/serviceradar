package sweeper

import (
    "context"
    "testing"
    "time"

    "github.com/golang/mock/gomock"
    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/pkg/models"
)

// Test that each sweep clears previous results so availability reflects current state only.
func TestRunSweep_ClearsPreviousResults(t *testing.T) {
    t.Parallel()
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()

    mockStore := NewMockStore(ctrl)
    log := logger.NewTestLogger()

    cfg := &models.Config{
        // No networks or device targets to avoid running actual scans
        Networks:      []string{},
        DeviceTargets: []models.DeviceTarget{},
        SweepModes:    []models.SweepMode{},
        Ports:         []int{},
        Interval:      1 * time.Minute,
        Timeout:       2 * time.Second,
        Concurrency:   10,
        AgentID:       "test-agent",
        PollerID:      "test-agent",
        Partition:     "default",
    }

    // Minimal processor (doesn't affect this test path)
    processor := NewBaseProcessor(cfg, log)

    // Expect PruneResults to be called once at the start of the sweep with age=0
    mockStore.EXPECT().PruneResults(gomock.Any(), time.Duration(0)).Return(nil).Times(1)

    sweeper, err := NewNetworkSweeper(cfg, mockStore, processor, nil, nil, "agents/test/checkers/sweep/sweep.json", log)
    if err != nil {
        t.Fatalf("failed to create sweeper: %v", err)
    }

    // Run a single sweep; with no targets this should be quick and still invoke PruneResults
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    if err := sweeper.runSweep(ctx); err != nil {
        t.Fatalf("runSweep returned error: %v", err)
    }

    // gomock assertion will validate the expectation
}
