package agent

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan/banner_grab"
	"github.com/carverauto/serviceradar/go/pkg/sweeper"
	"github.com/carverauto/serviceradar/proto"
)

const (
	testCancelSweepGroupID     = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
	testCancelSweepExecutionID = "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e"
)

// heldSweepGroup is one sweep group backed by a real NetworkSweeper whose runs
// stay in flight until released or cancelled. The banner-grab observation
// handler runs inside every sweep, so blocking it holds a run open without
// scanning anything.
type heldSweepGroup struct {
	multi   *MultiSweepService
	sweeper *sweeper.NetworkSweeper
	store   sweeper.Store
	started chan struct{}
	release chan struct{}
}

func newHeldSweepGroup(t *testing.T) *heldSweepGroup {
	t.Helper()

	log := createTestLogger()
	config := &models.Config{
		SweepGroupID: testCancelSweepGroupID,
		SweepModes:   []models.SweepMode{models.ModeTCPConnect},
		Interval:     time.Hour,
		BannerGrab:   models.BannerGrab{Enabled: true},
	}
	group := &heldSweepGroup{
		started: make(chan struct{}),
		release: make(chan struct{}),
	}

	hold := func(ctx context.Context, _ models.BannerGrab, _ *banner_grab.Engine, _ <-chan banner_grab.BannerObservation) error {
		select {
		case group.started <- struct{}{}:
		case <-ctx.Done():
			return nil
		}

		select {
		case <-group.release:
		case <-ctx.Done():
		}

		// Return cleanly even when cancelled, so a cancelled run still reaches
		// the step that would publish it.
		return nil
	}

	processor := sweeper.NewBaseProcessor(config, log)
	group.store = sweeper.NewInMemoryStore(processor, log)

	netSweeper, err := sweeper.NewNetworkSweeper(config, group.store, processor, nil, log, sweeper.WithBannerObservationHandler(hold))
	require.NoError(t, err)
	group.sweeper = netSweeper

	svc := &SweepService{
		sweeper:      netSweeper,
		config:       config,
		stats:        newScanStats(),
		logger:       log,
		sweepGroupID: testCancelSweepGroupID,
	}
	group.multi = &MultiSweepService{
		groups:         map[string]*SweepService{testCancelSweepGroupID: svc},
		groupSequences: map[string]string{testCancelSweepGroupID: ""},
		groupOrder:     []string{testCancelSweepGroupID},
		logger:         log,
	}

	return group
}

func (g *heldSweepGroup) waitStarted(t *testing.T) {
	t.Helper()

	select {
	case <-g.started:
	case <-time.After(5 * time.Second):
		t.Fatal("sweep run never started")
	}
}

// saveResult stands in for a scanner reporting a host during the held run.
func (g *heldSweepGroup) saveResult(t *testing.T, host string) {
	t.Helper()

	now := time.Now()
	require.NoError(t, g.store.SaveResult(context.Background(), &models.Result{
		Target:    models.Target{Host: host, Port: 80, Mode: models.ModeTCPConnect},
		Available: true,
		FirstSeen: now,
		LastSeen:  now,
	}))
}

func newSweepCancelLoop(services ...Service) *PushLoop {
	return &PushLoop{
		logger: createTestLogger(),
		server: &Server{services: services},
	}
}

func sweepCommand(id, commandType, payload string) *proto.CommandRequest {
	return &proto.CommandRequest{
		CommandId:   id,
		CommandType: commandType,
		PayloadJson: []byte(payload),
	}
}

func sweepCancelCommand(id, groupID string) *proto.CommandRequest {
	return sweepCommand(id, commandTypeSweepCancel,
		`{"sweep_group_id":"`+groupID+`","execution_id":"`+testCancelSweepExecutionID+`"}`)
}

func commandResultPayload(t *testing.T, result *proto.CommandResult) map[string]any {
	t.Helper()

	payload := map[string]any{}
	require.NoError(t, json.Unmarshal(result.GetPayloadJson(), &payload))

	return payload
}

func TestHandleSweepCancelAbortsInFlightRun(t *testing.T) {
	t.Parallel()

	group := newHeldSweepGroup(t)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := newSweepCancelLoop(group.multi)
	runPayload := `{"sweep_group_id":"` + testCancelSweepGroupID + `"}`

	// A completed sweep that has already been streamed and acknowledged.
	loop.handleCommand(t.Context(), sweepCommand("cmd-run-1", commandTypeSweepRun, runPayload), sender)
	group.waitStarted(t)
	group.saveResult(t, "192.0.2.10")
	group.release <- struct{}{}
	require.True(t, waitForCommandResult(t, stream, "cmd-run-1").GetSuccess())

	first, err := group.multi.GetSweepResults(t.Context(), "")
	require.NoError(t, err)
	require.True(t, first.GetHasNewData())
	group.multi.AcknowledgeSweepResults(first.GetSweepGroupId(), first.GetCurrentSequence())

	// A second run reports a host, then is cancelled while in flight.
	loop.handleCommand(t.Context(), sweepCommand("cmd-run-2", commandTypeSweepRun, runPayload), sender)
	group.waitStarted(t)
	group.saveResult(t, "192.0.2.11")

	loop.handleCommand(t.Context(), sweepCancelCommand("cmd-cancel", testCancelSweepGroupID), sender)

	cancel := waitForCommandResult(t, stream, "cmd-cancel")
	require.True(t, cancel.GetSuccess(), cancel.GetMessage())
	require.Equal(t, "sweep run cancelled", cancel.GetMessage())
	require.Equal(t, map[string]any{
		"sweep_group_id": testCancelSweepGroupID,
		"execution_id":   testCancelSweepExecutionID,
		"cancelled":      true,
	}, commandResultPayload(t, cancel))

	run := waitForCommandResult(t, stream, "cmd-run-2")
	require.False(t, run.GetSuccess())
	require.Equal(t, sweeper.ErrSweepCancelled.Error(), run.GetMessage())

	// Nothing from the aborted run is served or streamed: the sweep keeps
	// reporting the last completed run.
	status, err := group.sweeper.GetStatus(t.Context())
	require.NoError(t, err)
	require.Len(t, status.Hosts, 1)
	require.Equal(t, "192.0.2.10", status.Hosts[0].Host)

	next, err := group.multi.GetSweepResults(t.Context(), "")
	require.NoError(t, err)
	require.False(t, next.GetHasNewData())
}

func TestHandleSweepCancelWithNothingRunning(t *testing.T) {
	t.Parallel()

	group := newHeldSweepGroup(t)
	stream := &fakeControlStreamClient{}
	loop := newSweepCancelLoop(group.multi)

	loop.handleCommand(t.Context(), sweepCancelCommand("cmd-cancel-idle", testCancelSweepGroupID), newControlStreamSender(stream))

	result := waitForCommandResult(t, stream, "cmd-cancel-idle")
	require.True(t, result.GetSuccess(), result.GetMessage())
	require.Equal(t, "no sweep run in progress", result.GetMessage())
	require.Equal(t, map[string]any{
		"sweep_group_id": testCancelSweepGroupID,
		"execution_id":   testCancelSweepExecutionID,
		"cancelled":      false,
	}, commandResultPayload(t, result))
}

func TestHandleSweepCancelRejectsBadRequests(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name           string
		noSweepService bool
		payload        string
		message        string
	}{
		{name: "malformed payload", payload: `{"sweep_group_id":`, message: "invalid sweep cancel payload"},
		{name: "empty payload", payload: ``, message: "missing sweep_group_id"},
		{name: "missing group", payload: `{"execution_id":"` + testCancelSweepExecutionID + `"}`, message: "missing sweep_group_id"},
		{
			name:    "unknown group",
			payload: `{"sweep_group_id":"c3d4e5f6-a7b8-4c9d-8e0f-2a3b4c5d6e7f"}`,
			message: errSweepGroupNotFound.Error(),
		},
		{
			name:           "no sweep service",
			noSweepService: true,
			payload:        `{"sweep_group_id":"` + testCancelSweepGroupID + `"}`,
			message:        errSweepRunnerUnavailable.Error(),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			var services []Service
			if !tt.noSweepService {
				services = append(services, newHeldSweepGroup(t).multi)
			}

			stream := &fakeControlStreamClient{}
			loop := newSweepCancelLoop(services...)
			loop.handleCommand(t.Context(), sweepCommand("cmd-bad", commandTypeSweepCancel, tt.payload), newControlStreamSender(stream))

			result := waitForCommandResult(t, stream, "cmd-bad")
			require.False(t, result.GetSuccess())
			require.Equal(t, tt.message, result.GetMessage())
			require.Empty(t, result.GetPayloadJson())
		})
	}
}

// TestCancelSweepGroupRacesConfigReload cancels while config reloads add and
// remove the group. Each cancel must either find nothing running or find the
// group gone, never panic or race.
func TestCancelSweepGroupRacesConfigReload(t *testing.T) {
	t.Parallel()

	multi, err := NewMultiSweepService(&ServerConfig{AgentID: "agent-test", Partition: "default"}, nil, createTestLogger())
	require.NoError(t, err)

	group := SweepGroupConfig{
		SweepGroupID: testCancelSweepGroupID,
		SweepModes:   []models.SweepMode{models.ModeTCPConnect},
		Interval:     Duration(time.Hour),
	}

	var wg sync.WaitGroup

	wg.Add(2)

	go func() {
		defer wg.Done()

		for i := 0; i < 50; i++ {
			groups := []SweepGroupConfig{group}
			if i%2 == 1 {
				groups = nil
			}

			if err := multi.UpdateSweepGroupsContext(t.Context(), &SweepGroupsConfig{Groups: groups, ConfigHash: strconv.Itoa(i)}); err != nil {
				t.Errorf("reload %d: %v", i, err)
			}
		}
	}()

	go func() {
		defer wg.Done()

		for i := 0; i < 200; i++ {
			cancelled, err := multi.CancelSweepGroup(testCancelSweepGroupID)
			if err != nil && !errors.Is(err, errSweepGroupNotFound) {
				t.Errorf("cancel %d: %v", i, err)
			}

			if cancelled {
				t.Errorf("cancel %d reported a run, but none was started", i)
			}
		}
	}()

	wg.Wait()
}

func TestAgentCapabilitiesAdvertiseSweepCancel(t *testing.T) {
	t.Parallel()

	capabilities := agentCapabilities(agentCapabilityOptions{})
	require.True(t, slices.Contains(capabilities, "sweep"), "%#v", capabilities)
	require.True(t, slices.Contains(capabilities, "sweep_cancel"), "%#v", capabilities)
}
