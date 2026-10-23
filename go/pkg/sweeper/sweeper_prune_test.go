package sweeper

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/rs/zerolog"
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

	if err := sweeper.completeSuccessfulSweep(ctx, time.Now().Add(1*time.Minute), false); err != nil {
		t.Fatalf("completeSuccessfulSweep returned error: %v", err)
	}
}

// infoCaptureLogger records Info events and discards every other level.
type infoCaptureLogger struct {
	logger.Logger
	output zerolog.Logger
}

func (l infoCaptureLogger) Info() *zerolog.Event { return l.output.Info() }

func TestRunSweep_EmptyConfigDoesNotClaimAScan(t *testing.T) {
	t.Parallel()
	ctrl := gomock.NewController(t)

	var output bytes.Buffer
	log := infoCaptureLogger{
		Logger: logger.NewTestLogger(),
		output: zerolog.New(&output),
	}

	cfg := &models.Config{
		Networks:      []string{},
		DeviceTargets: []models.DeviceTarget{},
		SweepModes:    []models.SweepMode{},
		Ports:         []int{},
		Interval:      time.Minute,
		Timeout:       2 * time.Second,
		Concurrency:   10,
		AgentID:       "test-agent",
		GatewayID:     "test-agent",
		Partition:     "default",
	}

	mockStore := NewMockStore(ctrl)
	mockStore.EXPECT().PruneResults(gomock.Any(), gomock.AssignableToTypeOf(time.Duration(0))).Return(nil).Times(1)
	mockStore.EXPECT().GetSweepSummary(gomock.Any()).Return(&models.SweepSummary{}, nil).Times(1)

	processor := NewBaseProcessor(cfg, log)
	sweeper, err := NewNetworkSweeper(cfg, mockStore, processor, nil, log)
	if err != nil {
		t.Fatalf("failed to create sweeper: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := sweeper.runSweep(ctx); err != nil {
		t.Fatalf("runSweep returned error: %v", err)
	}

	logged := output.String()
	if strings.Contains(logged, "Starting sweep") || strings.Contains(logged, "Sweep completed successfully") {
		t.Fatalf("empty config claimed a scan: %s", logged)
	}
	if strings.Count(logged, "Nothing to scan") != 1 {
		t.Fatalf("expected one nothing-to-scan log, got %q", logged)
	}
}
