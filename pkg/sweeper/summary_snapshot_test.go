package sweeper

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestGetSummary_HostResultsDoNotAliasInternalState(t *testing.T) {
	cfg := &models.Config{Ports: []int{80}}
	processor := NewBaseProcessor(cfg, logger.NewTestLogger())

	hostAddr := "192.168.1.1"

	if err := processor.Process(&models.Result{
		Target:    models.Target{Host: hostAddr, Mode: models.ModeICMP},
		Available: true,
		RespTime:  10 * time.Millisecond,
	}); err != nil {
		t.Fatalf("process icmp: %v", err)
	}

	if err := processor.Process(&models.Result{
		Target:    models.Target{Host: hostAddr, Port: 80, Mode: models.ModeTCP},
		Available: true,
		RespTime:  5 * time.Millisecond,
	}); err != nil {
		t.Fatalf("process tcp: %v", err)
	}

	internal := processor.GetHostMap()[hostAddr]
	if internal == nil {
		t.Fatalf("expected internal host to exist")
	}
	if internal.ICMPStatus == nil || internal.PortMap == nil || len(internal.PortResults) == 0 {
		t.Fatalf("expected internal host to have ICMPStatus and port state")
	}

	summary, err := processor.GetSummary(context.Background())
	if err != nil {
		t.Fatalf("get summary: %v", err)
	}
	if len(summary.Hosts) != 1 {
		t.Fatalf("expected 1 host in summary, got %d", len(summary.Hosts))
	}

	snapshot := summary.Hosts[0]

	if snapshot.ICMPStatus == nil {
		t.Fatalf("expected snapshot ICMPStatus to be non-nil")
	}
	if snapshot.ICMPStatus == internal.ICMPStatus {
		t.Fatalf("expected ICMPStatus to be deep-copied")
	}

	if snapshot.PortMap == nil {
		t.Fatalf("expected snapshot PortMap to be non-nil")
	}
	if len(snapshot.PortResults) == 0 {
		t.Fatalf("expected snapshot PortResults to be non-empty")
	}

	for port, internalPR := range internal.PortMap {
		snapshotPR := snapshot.PortMap[port]
		if internalPR == nil || snapshotPR == nil {
			continue
		}
		if internalPR == snapshotPR {
			t.Fatalf("expected PortMap[%d] to be deep-copied", port)
		}
	}

	internalPointers := make(map[*models.PortResult]struct{}, len(internal.PortResults))
	for _, pr := range internal.PortResults {
		internalPointers[pr] = struct{}{}
	}
	for _, pr := range snapshot.PortResults {
		if _, ok := internalPointers[pr]; ok {
			t.Fatalf("expected PortResults to be deep-copied (found shared pointer)")
		}
	}

	for _, pr := range snapshot.PortResults {
		if pr == nil {
			continue
		}
		if got := snapshot.PortMap[pr.Port]; got != pr {
			t.Fatalf("expected snapshot PortMap[%d] to reference the same PortResult pointer as PortResults", pr.Port)
		}
	}
}

func TestGetSummary_ConcurrentReadsDoNotPanic(t *testing.T) {
	cfg := &models.Config{Ports: []int{80}}
	processor := NewBaseProcessor(cfg, logger.NewTestLogger())

	hostAddr := "192.168.1.1"

	if err := processor.Process(&models.Result{
		Target:    models.Target{Host: hostAddr, Port: 80, Mode: models.ModeTCP},
		Available: true,
		RespTime:  5 * time.Millisecond,
	}); err != nil {
		t.Fatalf("process tcp: %v", err)
	}

	summary, err := processor.GetSummary(context.Background())
	if err != nil {
		t.Fatalf("get summary: %v", err)
	}
	if len(summary.Hosts) != 1 {
		t.Fatalf("expected 1 host in summary, got %d", len(summary.Hosts))
	}
	snapshot := summary.Hosts[0]

	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}

			if snapshot.PortMap != nil {
				_ = snapshot.PortMap[80]
				_ = len(snapshot.PortMap)
			}

			if len(snapshot.PortResults) > 0 && snapshot.PortResults[0] != nil {
				_ = snapshot.PortResults[0].Port
			}
		}
	}()

	for i := 0; i < 250; i++ {
		if err := processor.Process(&models.Result{
			Target:    models.Target{Host: hostAddr, Port: 10000 + i, Mode: models.ModeTCP},
			Available: true,
			RespTime:  1 * time.Millisecond,
		}); err != nil {
			close(stop)
			wg.Wait()
			t.Fatalf("process tcp iteration %d: %v", i, err)
		}
	}

	close(stop)
	wg.Wait()
}
