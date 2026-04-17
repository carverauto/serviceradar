package mtr

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestExpireTimedOutProbes_DecrementsInFlight(t *testing.T) {
	t.Parallel()

	tracer := &Tracer{
		opts: Options{
			Timeout: 100 * time.Millisecond,
		},
		hops: []*HopResult{
			NewHopResult(1, DefaultRingBufferSize),
		},
		probes: map[int]probeRecord{
			1: {
				hopIndex: 0,
				seq:      1,
				sentAt:   time.Now().Add(-200 * time.Millisecond),
			},
		},
		expiredScratch: make([]probeRecord, 0, 4),
	}

	tracer.hops[0].InFlight = 1
	tracer.expireTimedOutProbes(time.Now())

	if got := tracer.hops[0].InFlight; got != 0 {
		t.Fatalf("expected InFlight=0 after timeout sweep, got %d", got)
	}

	if got := len(tracer.probes); got != 0 {
		t.Fatalf("expected no in-flight probes after timeout sweep, got %d", got)
	}
	if got := len(tracer.expiredScratch); got != 0 {
		t.Fatalf("expected expired scratch to be reset, got len %d", got)
	}
	if got := cap(tracer.expiredScratch); got != 4 {
		t.Fatalf("expected expired scratch capacity to be reused, got %d", got)
	}
}

func TestNewTracer_TCPSupported(t *testing.T) {
	t.Parallel()

	opts := DefaultOptions("localhost")
	opts.Protocol = ProtocolTCP

	tracer, err := NewTracer(t.Context(), opts, logger.NewTestLogger())
	if err != nil {
		t.Fatalf("expected TCP tracer to initialize, got error: %v", err)
	}

	if tracer == nil {
		t.Fatal("expected non-nil tracer")
	}
}

func TestNewTracerWithResources_UsesResolvedTargetAndSharedSocket(t *testing.T) {
	t.Parallel()

	socket := &fakeRawSocket{}
	opts := DefaultOptions("does-not-need-to-resolve.invalid")
	opts.MaxHops = 1
	opts.ProbesPerHop = 1
	opts.Timeout = 5 * time.Millisecond
	opts.DNSResolve = false

	tracer, err := NewTracerWithResources(
		context.Background(),
		opts,
		logger.NewTestLogger(),
		TracerResources{
			Target: &TargetInfo{
				IP:        net.ParseIP("127.0.0.1").To4(),
				IPVersion: 4,
			},
			Socket: socket,
		},
	)
	if err != nil {
		t.Fatalf("expected resolved target override to avoid DNS failure, got %v", err)
	}

	runCtx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	if _, err := tracer.Run(runCtx); err != nil {
		t.Fatalf("expected run to complete with shared socket, got %v", err)
	}

	if socket.closeCalls != 0 {
		t.Fatalf("expected shared socket to remain open, got %d closes", socket.closeCalls)
	}

	if err := tracer.Close(); err != nil {
		t.Fatalf("expected tracer close to succeed, got %v", err)
	}

	if socket.closeCalls != 0 {
		t.Fatalf("expected tracer close to skip shared socket, got %d closes", socket.closeCalls)
	}
}

func TestResolveTarget_LiteralIPSkipsDNSLookup(t *testing.T) {
	t.Parallel()

	target, err := ResolveTarget(context.Background(), "127.0.0.1")
	if err != nil {
		t.Fatalf("expected literal IP resolution to succeed, got %v", err)
	}

	if target.IPVersion != 4 {
		t.Fatalf("expected IPv4 target, got version %d", target.IPVersion)
	}
	if got := target.IP.String(); got != "127.0.0.1" {
		t.Fatalf("expected loopback IP, got %s", got)
	}
}

func TestTracerResetForTarget_ReusesExistingHopBuffers(t *testing.T) {
	t.Parallel()

	socket := &fakeRawSocket{}
	opts := DefaultOptions("127.0.0.1")
	opts.MaxHops = 2
	opts.ProbesPerHop = 1
	opts.Timeout = 5 * time.Millisecond
	opts.DNSResolve = false

	tracer, err := NewTracerWithResources(
		context.Background(),
		opts,
		logger.NewTestLogger(),
		TracerResources{
			Target: &TargetInfo{
				IP:        net.ParseIP("127.0.0.1").To4(),
				IPVersion: 4,
			},
			Socket: socket,
		},
	)
	if err != nil {
		t.Fatalf("expected tracer creation to succeed, got %v", err)
	}

	runCtx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	if _, err := tracer.Run(runCtx); err != nil {
		t.Fatalf("expected initial run to succeed, got %v", err)
	}

	firstHop := tracer.hops[0]
	firstPayloadCap := cap(tracer.payload)

	if err := tracer.ResetForTarget(opts, &TargetInfo{
		IP:        net.ParseIP("127.0.0.2").To4(),
		IPVersion: 4,
	}); err != nil {
		t.Fatalf("expected reset to succeed, got %v", err)
	}

	runCtx2, cancel2 := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel2()

	if _, err := tracer.Run(runCtx2); err != nil {
		t.Fatalf("expected second run to succeed, got %v", err)
	}

	if tracer.hops[0] != firstHop {
		t.Fatal("expected hop buffer to be reused across runs")
	}
	if cap(tracer.payload) != firstPayloadCap {
		t.Fatal("expected payload buffer capacity to be reused across runs")
	}
}

func TestWaitForProbeInterval_StopsOnContextCancel(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if waitForProbeInterval(ctx, time.Second) {
		t.Fatal("expected canceled context to stop probe interval wait")
	}
}

func TestWaitForOutstandingProbes_ReturnsWhenPendingSetClears(t *testing.T) {
	t.Parallel()

	tracer := &Tracer{
		probes: map[int]probeRecord{
			1: {seq: 1},
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	tracer.probeUpdateCh = make(chan struct{}, 1)

	go func() {
		time.Sleep(20 * time.Millisecond)
		tracer.probesMu.Lock()
		delete(tracer.probes, 1)
		tracer.probesMu.Unlock()
		tracer.signalProbeStateChanged()
	}()

	startedAt := time.Now()
	tracer.waitForOutstandingProbes(ctx)
	elapsed := time.Since(startedAt)

	if elapsed >= 150*time.Millisecond {
		t.Fatalf("expected outstanding probe wait to stop early, took %s", elapsed)
	}
}

type fakeRawSocket struct {
	closeCalls int
}

func (f *fakeRawSocket) SendICMP(_ net.IP, _ int, _ int, _ int, _ []byte) error { return nil }
func (f *fakeRawSocket) SendUDP(_ net.IP, _ int, _ int, _ int, _ []byte) error  { return nil }
func (f *fakeRawSocket) SendTCP(_ net.IP, _ int, _ int, _ int) error            { return nil }
func (f *fakeRawSocket) Receive(deadline time.Time) (*ICMPResponse, error) {
	time.Sleep(time.Until(deadline))
	return nil, fakeTimeoutError{}
}
func (f *fakeRawSocket) Close() error {
	f.closeCalls++
	return nil
}
func (f *fakeRawSocket) IsIPv6() bool { return false }

type fakeTimeoutError struct{}

func (fakeTimeoutError) Error() string   { return "timeout" }
func (fakeTimeoutError) Timeout() bool   { return true }
func (fakeTimeoutError) Temporary() bool { return true }
