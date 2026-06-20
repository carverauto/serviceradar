package sweeper

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"go.uber.org/mock/gomock"
)

// Test that each successful sweep prunes only pre-sweep results after the
// current result set has been collected.
func TestRunSweep_PrunesPreviousResultsAfterSuccessfulSweep(t *testing.T) {
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
		GatewayID:     "test-agent",
		Partition:     "default",
	}

	// Minimal processor (doesn't affect this test path)
	processor := NewBaseProcessor(cfg, log)

	mockStore.EXPECT().PruneResults(gomock.Any(), gomock.AssignableToTypeOf(time.Duration(0))).Return(nil).Times(1)
	mockStore.EXPECT().GetSweepSummary(gomock.Any()).Return(&models.SweepSummary{}, nil).Times(1)

	sweeper, err := NewNetworkSweeper(cfg, mockStore, processor, nil, log)
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

func TestCompleteSuccessfulSweep_SkipsPruneWhenStartedAtIsFuture(t *testing.T) {
	t.Parallel()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockStore := NewMockStore(ctrl)
	log := logger.NewTestLogger()

	cfg := &models.Config{
		Networks:      []string{},
		DeviceTargets: []models.DeviceTarget{},
		SweepModes:    []models.SweepMode{},
		Ports:         []int{},
		Interval:      1 * time.Minute,
		Timeout:       2 * time.Second,
		Concurrency:   10,
		AgentID:       "test-agent",
		GatewayID:     "test-agent",
		Partition:     "default",
	}

	processor := NewBaseProcessor(cfg, log)
	mockStore.EXPECT().GetSweepSummary(gomock.Any()).Return(&models.SweepSummary{}, nil).Times(1)

	sweeper, err := NewNetworkSweeper(cfg, mockStore, processor, nil, log)
	if err != nil {
		t.Fatalf("failed to create sweeper: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := sweeper.completeSuccessfulSweep(ctx, time.Now().Add(1*time.Minute)); err != nil {
		t.Fatalf("completeSuccessfulSweep returned error: %v", err)
	}
}
