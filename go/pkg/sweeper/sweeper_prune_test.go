package sweeper

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
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

type capturedInfoEvent struct {
	Level             string `json:"level"`
	Message           string `json:"message"`
	NetworkCount      *int   `json:"networkCount"`
	DeviceTargetCount *int   `json:"deviceTargetCount"`
	ICMPTargets       *int   `json:"icmpTargets"`
	TCPTargets        *int   `json:"tcpTargets"`
	TCPConnectTargets *int   `json:"tcpConnectTargets"`
}

func emptySweepConfig() *models.Config {
	return &models.Config{
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
}

// runSweepCapturingInfo runs one sweep. The mock store is the prune contract:
// a successful run calls PruneResults once and GetSweepSummary once.
func runSweepCapturingInfo(t *testing.T, cfg *models.Config) []capturedInfoEvent {
	t.Helper()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	var output bytes.Buffer

	log := infoCaptureLogger{
		Logger: logger.NewTestLogger(),
		output: zerolog.New(&output),
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

	return decodeCapturedInfo(t, output.String())
}

func decodeCapturedInfo(t *testing.T, logged string) []capturedInfoEvent {
	t.Helper()

	dec := json.NewDecoder(bytes.NewReader([]byte(logged)))

	var events []capturedInfoEvent

	for {
		var event capturedInfoEvent

		err := dec.Decode(&event)
		if err == io.EOF {
			break
		}

		if err != nil {
			t.Fatalf("info log is not JSON: %v\n%s", err, logged)
		}

		events = append(events, event)
	}

	return events
}

func eventsWithMessage(events []capturedInfoEvent, message string) []capturedInfoEvent {
	var matched []capturedInfoEvent

	for _, event := range events {
		if event.Message == message {
			matched = append(matched, event)
		}
	}

	return matched
}

func requireOneMessage(t *testing.T, events []capturedInfoEvent, message string) capturedInfoEvent {
	t.Helper()

	matched := eventsWithMessage(events, message)
	if len(matched) != 1 {
		t.Fatalf("expected one %q info event, got %d in %+v", message, len(matched), events)
	}

	return matched[0]
}

func requireNoMessage(t *testing.T, events []capturedInfoEvent, message string) {
	t.Helper()

	matched := eventsWithMessage(events, message)
	if len(matched) != 0 {
		t.Fatalf("did not expect %q, got %+v", message, events)
	}
}

func TestRunSweep_EmptyConfigDoesNotClaimAScan(t *testing.T) {
	t.Parallel()

	events := runSweepCapturingInfo(t, emptySweepConfig())
	t.Logf("empty-config info events: %+v", events)

	requireNoMessage(t, events, "Starting sweep")
	requireNoMessage(t, events, "Sweep completed successfully")

	event := requireOneMessage(t, events, "Nothing to scan")
	if event.Level != "info" {
		t.Fatalf("nothing-to-scan level = %q, want info", event.Level)
	}

	if event.NetworkCount == nil || *event.NetworkCount != 0 || event.DeviceTargetCount == nil || *event.DeviceTargetCount != 0 {
		t.Fatalf("expected networkCount 0 and deviceTargetCount 0, got %+v", event)
	}
}

// 192.0.2.0/31 expands to zero hosts: ExpandCIDR skips both the network and
// broadcast addresses, and countCIDRHosts documents that an IPv4 /31 counts
// as 0. The sweep is still configured, so it must keep the scan logs.
func TestRunSweep_ConfiguredNetworkWithZeroHostsStillLogsAScan(t *testing.T) {
	t.Parallel()

	cfg := emptySweepConfig()
	cfg.Networks = []string{"192.0.2.0/31"}
	cfg.SweepModes = []models.SweepMode{models.ModeICMP}

	events := runSweepCapturingInfo(t, cfg)
	t.Logf("zero-host network info events: %+v", events)

	requireNoMessage(t, events, "Nothing to scan")
	requireOneMessage(t, events, "Sweep completed successfully")

	started := requireOneMessage(t, events, "Starting sweep")
	if started.ICMPTargets == nil || *started.ICMPTargets != 0 ||
		started.TCPTargets == nil || *started.TCPTargets != 0 ||
		started.TCPConnectTargets == nil || *started.TCPConnectTargets != 0 {
		t.Fatalf("zero-host network should log a sweep with no generated targets, got %+v", started)
	}
}

// Gate on both config counts. A device target with no global networks is a
// sweep even when that target expands to zero hosts.
func TestRunSweep_DeviceTargetWithoutNetworksStillLogsAScan(t *testing.T) {
	t.Parallel()

	cfg := emptySweepConfig()
	cfg.DeviceTargets = []models.DeviceTarget{{
		Network:    "192.0.2.0/31",
		SweepModes: []models.SweepMode{models.ModeICMP},
	}}

	events := runSweepCapturingInfo(t, cfg)
	t.Logf("device-target-only info events: %+v", events)

	requireNoMessage(t, events, "Nothing to scan")
	requireOneMessage(t, events, "Starting sweep")
	requireOneMessage(t, events, "Sweep completed successfully")
}
