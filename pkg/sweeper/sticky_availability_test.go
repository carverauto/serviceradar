package sweeper

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Demonstrates sticky availability when an old successful TCP result persists while
// subsequent sweeps stop scanning that port (e.g., port list change) and only produce
// failures for other modes/ports. Without pruning, availability remains true.
func TestStickyAvailability_WhenPortListChanges_WithoutPrune(t *testing.T) {
	t.Parallel()

	log := logger.NewTestLogger()

	cfg := &models.Config{SweepModes: []models.SweepMode{models.ModeTCP, models.ModeICMP}}
	processor := NewBaseProcessor(cfg, log)
	store := NewInMemoryStore(processor, log)
	if closer, ok := store.(interface{ Close() error }); ok {
		t.Cleanup(func() { _ = closer.Close() })
	}

	ctx := context.Background()
	host := "10.0.0.1"

	// Prior sweep: TCP 80 was open (success)
	resOld := &models.Result{
		Target:    models.Target{Host: host, Port: 80, Mode: models.ModeTCP},
		Available: true,
		LastSeen:  time.Now().Add(-time.Hour),
	}
	if err := store.SaveResult(ctx, resOld); err != nil {
		t.Fatalf("save old result: %v", err)
	}

	// New sweep: port list changed (80 not scanned); only ICMP scanned and blocked (failure)
	resNew := &models.Result{
		Target:    models.Target{Host: host, Mode: models.ModeICMP},
		Available: false,
		LastSeen:  time.Now(),
	}
	if err := store.SaveResult(ctx, resNew); err != nil {
		t.Fatalf("save new result: %v", err)
	}

	summary, err := store.GetSweepSummary(ctx)
	if err != nil {
		t.Fatalf("get summary: %v", err)
	}

	if len(summary.Hosts) == 0 {
		t.Fatalf("expected host in summary")
	}

	if !summary.Hosts[0].Available {
		t.Fatalf("expected sticky availability true due to old TCP:80 success persisting")
	}

	// Now prune (simulating our fix) and re-add only the current (failing) result
	if err := store.PruneResults(ctx, 0); err != nil {
		t.Fatalf("prune: %v", err)
	}
	if err := store.SaveResult(ctx, resNew); err != nil {
		t.Fatalf("save new result after prune: %v", err)
	}

	summary2, err := store.GetSweepSummary(ctx)
	if err != nil {
		t.Fatalf("get summary2: %v", err)
	}

	if len(summary2.Hosts) == 0 {
		t.Fatalf("expected host in summary2")
	}

	if summary2.Hosts[0].Available {
		t.Fatalf("expected availability false after pruning old successes")
	}
}
