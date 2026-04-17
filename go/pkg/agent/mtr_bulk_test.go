package agent

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/mtr"
)

func TestNormalizeBulkMtrTargets(t *testing.T) {
	targets := normalizeBulkMtrTargets([]string{" 1.1.1.1 ", "", "1.1.1.1", "example.com"})

	if len(targets) != 2 {
		t.Fatalf("expected 2 targets, got %d", len(targets))
	}
	if targets[0] != "1.1.1.1" || targets[1] != "example.com" {
		t.Fatalf("unexpected targets: %#v", targets)
	}
}

func TestNormalizeBulkMtrConcurrency(t *testing.T) {
	if got := normalizeBulkMtrConcurrency(0, 10); got != 10 {
		t.Fatalf("expected concurrency capped to target count, got %d", got)
	}

	if got := normalizeBulkMtrConcurrency(999, 500); got != maxBulkMtrConcurrency {
		t.Fatalf("expected max concurrency %d, got %d", maxBulkMtrConcurrency, got)
	}
}

func TestCalculateBulkMtrProgress(t *testing.T) {
	if got := calculateBulkMtrProgress(5, 20); got != 25 {
		t.Fatalf("expected 25, got %d", got)
	}

	if got := calculateBulkMtrProgress(20, 20); got != 100 {
		t.Fatalf("expected 100, got %d", got)
	}
}

func TestCalculateTargetsPerMinute(t *testing.T) {
	got := calculateTargetsPerMinute(120, 30_000)

	if got != 240 {
		t.Fatalf("expected 240 targets/minute, got %v", got)
	}
}

func TestBulkMtrOptions_AppliesFastExecutionProfile(t *testing.T) {
	opts := bulkMtrOptions(mtrBulkRunPayload{ExecutionProfile: "fast"})

	if opts.MaxHops != fastBulkMaxHops {
		t.Fatalf("expected fast profile max hops %d, got %d", fastBulkMaxHops, opts.MaxHops)
	}
	if opts.ProbesPerHop != 3 {
		t.Fatalf("expected fast profile probes_per_hop=3, got %d", opts.ProbesPerHop)
	}
	if opts.ProbeInterval != 25*time.Millisecond {
		t.Fatalf("expected fast profile probe interval 25ms, got %s", opts.ProbeInterval)
	}
	if opts.DNSResolve {
		t.Fatal("expected fast profile to disable DNS resolution")
	}
	if opts.Timeout != fastBulkMtrTimeout {
		t.Fatalf("expected fast profile timeout %s, got %s", fastBulkMtrTimeout, opts.Timeout)
	}
	if opts.MaxUnknownHops != 5 {
		t.Fatalf("expected fast profile max unknown hops 5, got %d", opts.MaxUnknownHops)
	}
	if opts.RingBufferSize != fastBulkRingBufferSize {
		t.Fatalf("expected fast profile ring buffer size %d, got %d", fastBulkRingBufferSize, opts.RingBufferSize)
	}
}

func TestBulkMtrOptions_AppliesBalancedExecutionProfile(t *testing.T) {
	opts := bulkMtrOptions(mtrBulkRunPayload{ExecutionProfile: "balanced"})

	if opts.MaxHops != balancedBulkMaxHops {
		t.Fatalf("expected balanced profile max hops %d, got %d", balancedBulkMaxHops, opts.MaxHops)
	}
	if opts.ProbesPerHop != 5 {
		t.Fatalf("expected balanced profile probes_per_hop=5, got %d", opts.ProbesPerHop)
	}
	if opts.ProbeInterval != 50*time.Millisecond {
		t.Fatalf("expected balanced profile probe interval 50ms, got %s", opts.ProbeInterval)
	}
	if opts.DNSResolve {
		t.Fatal("expected balanced profile to disable DNS resolution")
	}
	if opts.Timeout != balancedBulkMtrTimeout {
		t.Fatalf("expected balanced profile timeout %s, got %s", balancedBulkMtrTimeout, opts.Timeout)
	}
	if opts.MaxUnknownHops != 7 {
		t.Fatalf("expected balanced profile max unknown hops 7, got %d", opts.MaxUnknownHops)
	}
	if opts.RingBufferSize != balancedBulkRingBufferSize {
		t.Fatalf("expected balanced profile ring buffer size %d, got %d", balancedBulkRingBufferSize, opts.RingBufferSize)
	}
}

func TestBulkMtrOptions_AppliesDeepExecutionProfile(t *testing.T) {
	opts := bulkMtrOptions(mtrBulkRunPayload{ExecutionProfile: "deep"})

	if opts.MaxHops != mtr.DefaultMaxHops {
		t.Fatalf("expected deep profile max hops %d, got %d", mtr.DefaultMaxHops, opts.MaxHops)
	}
	if opts.ProbesPerHop != mtr.DefaultProbesPerHop {
		t.Fatalf("expected deep profile probes_per_hop=%d, got %d", mtr.DefaultProbesPerHop, opts.ProbesPerHop)
	}
	if opts.ProbeInterval != time.Duration(mtr.DefaultProbeIntervalMs)*time.Millisecond {
		t.Fatalf("expected deep profile default probe interval, got %s", opts.ProbeInterval)
	}
	if !opts.DNSResolve {
		t.Fatal("expected deep profile to enable DNS resolution")
	}
	if opts.Timeout != mtr.DefaultTimeout {
		t.Fatalf("expected deep profile default timeout %s, got %s", mtr.DefaultTimeout, opts.Timeout)
	}
	if opts.MaxUnknownHops != mtr.DefaultMaxUnknownHops {
		t.Fatalf("expected deep profile max unknown hops %d, got %d", mtr.DefaultMaxUnknownHops, opts.MaxUnknownHops)
	}
	if opts.RingBufferSize != mtr.DefaultRingBufferSize {
		t.Fatalf("expected deep profile ring buffer size %d, got %d", mtr.DefaultRingBufferSize, opts.RingBufferSize)
	}
}

func TestBulkMtrOptions_ExplicitMaxHopsOverridesProfileDefault(t *testing.T) {
	opts := bulkMtrOptions(mtrBulkRunPayload{
		ExecutionProfile: "fast",
		MaxHops:          12,
	})

	if opts.MaxHops != 12 {
		t.Fatalf("expected explicit max hops override to win, got %d", opts.MaxHops)
	}
}

func TestBuildBulkMtrTargetUpdate_MapsCanceledContext(t *testing.T) {
	update := buildBulkMtrTargetUpdate("example.com", nil, context.Canceled)

	if update.Status != bulkMtrStatusCanceled {
		t.Fatalf("expected canceled status, got %q", update.Status)
	}
	if update.Error == "" {
		t.Fatal("expected canceled update to include an error message")
	}
}

func TestNormalizeBulkMtrResolverCount(t *testing.T) {
	if got := normalizeBulkMtrResolverCount(0); got != 1 {
		t.Fatalf("expected minimum resolver count of 1, got %d", got)
	}

	if got := normalizeBulkMtrResolverCount(4); got != 4 {
		t.Fatalf("expected resolver count to match small target count, got %d", got)
	}

	if got := normalizeBulkMtrResolverCount(128); got != 16 {
		t.Fatalf("expected resolver count cap of 16, got %d", got)
	}
}

func TestResolveBulkTargets_ProducesResolvedTasks(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	targetCh := make(chan string, 1)
	taskCh := make(chan bulkMtrTask, 1)
	targetCh <- "127.0.0.1"
	close(targetCh)

	go resolveBulkTargets(ctx, targetCh, taskCh)

	task, ok := nextBulkMtrTask(ctx, taskCh)
	if !ok {
		t.Fatal("expected resolved bulk task")
	}
	if task.target != "127.0.0.1" {
		t.Fatalf("expected target 127.0.0.1, got %q", task.target)
	}
	if task.err != nil {
		t.Fatalf("expected target resolution to succeed, got %v", task.err)
	}
	if task.info == nil {
		t.Fatal("expected resolved target info")
	}
	if task.info.IPVersion != 4 {
		t.Fatalf("expected IPv4 target, got version %d", task.info.IPVersion)
	}
}

func TestBulkMtrAdaptiveController_ReducesConcurrencyOnTimeoutPressure(t *testing.T) {
	controller := newBulkMtrAdaptiveController(64, time.Now())
	limit := atomic.Int32{}
	limit.Store(64)

	for i := 0; i < bulkMtrAdaptiveWindowSize; i++ {
		got := observeBulkMtrConcurrency(controller, bulkMtrStatusTimedOut, &limit)
		if got < 1 {
			t.Fatalf("expected adaptive concurrency to stay positive, got %d", got)
		}
	}

	if controller.current >= 64 {
		t.Fatalf("expected adaptive concurrency to back off, got %d", controller.current)
	}
	if limit.Load() != int32(controller.current) {
		t.Fatalf("expected exported limit %d to match controller current %d", limit.Load(), controller.current)
	}
}

func TestBulkMtrAdaptiveController_IncreasesConcurrencyAfterHealthyWindow(t *testing.T) {
	controller := newBulkMtrAdaptiveController(64, time.Now())
	controller.current = 16

	limit := atomic.Int32{}
	limit.Store(16)

	for i := 0; i < bulkMtrAdaptiveWindowSize; i++ {
		observeBulkMtrConcurrency(controller, bulkMtrStatusCompleted, &limit)
	}

	if controller.current <= 16 {
		t.Fatalf("expected adaptive concurrency to increase, got %d", controller.current)
	}
	if controller.current > 64 {
		t.Fatalf("expected adaptive concurrency to respect max 64, got %d", controller.current)
	}
}

func TestNextBulkMtrTarget_StopsWhenContextCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	target, ok := nextBulkMtrTarget(ctx, make(chan string))
	if ok {
		t.Fatal("expected canceled context to stop target intake")
	}
	if target != "" {
		t.Fatalf("expected empty target on cancellation, got %q", target)
	}
}

func TestSendBulkMtrEvent_StopsWhenContextCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if sendBulkMtrEvent(ctx, make(chan mtrBulkEvent), mtrBulkEvent{}) {
		t.Fatal("expected canceled context to prevent event send")
	}
}

func TestShouldFlushBulkMtrProgress_FlushesOnCompletion(t *testing.T) {
	now := time.Now()

	if !shouldFlushBulkMtrProgress(1, 10, 10, now, now) {
		t.Fatal("expected completed bulk progress to flush immediately")
	}
}

func TestShouldFlushBulkMtrProgress_FlushesOnBatchSize(t *testing.T) {
	now := time.Now()

	if !shouldFlushBulkMtrProgress(bulkMtrProgressBatchSize, 5, 10, now, now) {
		t.Fatal("expected batch-size threshold to flush progress")
	}
}

func TestShouldFlushBulkMtrProgress_FlushesOnInterval(t *testing.T) {
	now := time.Now()

	if !shouldFlushBulkMtrProgress(1, 5, 10, now.Add(-bulkMtrProgressInterval), now) {
		t.Fatal("expected progress interval threshold to flush progress")
	}
}

func TestShouldFlushBulkMtrProgress_HoldsSmallRecentBatch(t *testing.T) {
	now := time.Now()

	if shouldFlushBulkMtrProgress(1, 5, 10, now, now) {
		t.Fatal("expected small recent progress batch to stay buffered")
	}
}
