package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
)

var errOnDemandMtrRunsSerialised = errors.New("on-demand mtr runs were serialised")

// Two overlapping mtr.run commands must each report a result before the
// command expires, including when one trace engine never returns. Without
// that, core hears nothing until the command's deadline and the operator sees
// both traces time out.
func TestHandleMtrRun_ConcurrentRunsEachReportAResult(t *testing.T) {
	t.Parallel()

	var started sync.WaitGroup
	started.Add(2)
	bothStarted := make(chan struct{})
	go func() {
		started.Wait()
		close(bothStarted)
	}()

	releaseStuck := make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseStuck) }) }
	t.Cleanup(release)

	loop := &PushLoop{
		logger:         logger.NewTestLogger(),
		mtrOnDemandSem: make(chan struct{}, defaultMaxConcurrentOnDemandMtr),
		mtrOnDemandRun: func(_ context.Context, opts mtr.Options, _ logger.Logger) (*mtr.TraceResult, error) {
			started.Done()
			select {
			case <-bothStarted:
			case <-time.After(5 * time.Second):
				return nil, errOnDemandMtrRunsSerialised
			}

			if opts.Protocol == mtr.ProtocolUDP {
				// A trace engine that does not return, whatever its context says.
				<-releaseStuck
				return nil, context.DeadlineExceeded
			}

			return &mtr.TraceResult{
				Target:        opts.Target,
				TargetIP:      opts.Target,
				TargetReached: true,
				TotalHops:     1,
				Protocol:      opts.Protocol.String(),
			}, nil
		},
	}

	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)

	dispatch := func(commandID, protocol string) {
		body, err := json.Marshal(mtrRunPayload{Target: "192.0.2.10", Protocol: protocol})
		if err != nil {
			t.Fatalf("marshal payload: %v", err)
		}

		// A short TTL keeps the run deadline, and so the test, to a couple of seconds.
		loop.handleCommand(t.Context(), &proto.CommandRequest{
			CommandId:   commandID,
			CommandType: commandTypeMtrRun,
			PayloadJson: body,
			TtlSeconds:  2,
			CreatedAt:   time.Now().Unix(),
		}, sender)
	}

	dispatch("cmd-mtr-icmp", "icmp")
	dispatch("cmd-mtr-udp", "udp")

	icmp := waitForCommandResult(t, stream, "cmd-mtr-icmp")
	if !icmp.GetSuccess() {
		t.Fatalf("icmp run: expected success, got %q", icmp.GetMessage())
	}

	udp := waitForCommandResult(t, stream, "cmd-mtr-udp")
	if udp.GetSuccess() {
		t.Fatalf("stuck udp run: expected a failure result, got success")
	}
	if !strings.Contains(udp.GetMessage(), "deadline") {
		t.Fatalf("stuck udp run: message = %q, want a deadline failure", udp.GetMessage())
	}

	// The stuck trace still holds its slot, so it keeps counting against the
	// concurrency limit until its engine returns.
	if got := len(loop.mtrOnDemandSem); got != 1 {
		t.Fatalf("slots held after results = %d, want 1 (the stuck trace)", got)
	}

	release()

	deadline := time.Now().Add(2 * time.Second)
	for len(loop.mtrOnDemandSem) != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("stuck trace's slot not released after its engine returned (held=%d)", len(loop.mtrOnDemandSem))
		}
		time.Sleep(10 * time.Millisecond)
	}
}
