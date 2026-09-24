package mtr

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestTCPHandshakeStats_CountsRetransmitsDuplicatesAndDrops(t *testing.T) {
	t.Parallel()

	start := time.Now()
	hs := newTCPHandshake(9, 3)

	// Attempt 0: answered first time with a SYN-ACK, then the target re-sends it.
	hs.sent(MinPort, 0, false, start)
	hs.record(&TCPReply{Seq: MinPort, SYNACK: true, RecvTime: start.Add(10 * time.Millisecond)})
	hs.record(&TCPReply{Seq: MinPort, SYNACK: true, RecvTime: start.Add(30 * time.Millisecond)})

	// Attempt 1: lost, answered only after a retransmission, with an RST.
	hs.sent(MinPort+1, 1, false, start)
	hs.sent(MinPort+3, 1, true, start.Add(100*time.Millisecond))
	hs.record(&TCPReply{Seq: MinPort + 3, RST: true, RecvTime: start.Add(120 * time.Millisecond)})

	// Attempt 2: never answered.
	hs.sent(MinPort+2, 2, false, start)
	hs.sent(MinPort+4, 2, true, start.Add(100*time.Millisecond))

	if hs.record(&TCPReply{Seq: MinPort + 99, SYNACK: true, RecvTime: start}) {
		t.Fatal("expected a reply to an unknown sequence to be left to path probing")
	}

	stats := hs.stats(2)

	checks := map[string][2]int{
		"attempts":            {stats.Attempts, 3},
		"syn_sent":            {stats.SYNSent, 5},
		"synack_received":     {stats.SYNACKReceived, 1},
		"rst_received":        {stats.RSTReceived, 1},
		"unanswered":          {stats.Unanswered, 1},
		"syn_retransmits":     {stats.Retransmits, 2},
		"answered_after_retx": {stats.AnsweredAfterRetx, 1},
		"synack_duplicates":   {stats.SYNACKDuplicates, 1},
		"ack_mismatch":        {stats.AckMismatch, 2},
	}
	for name, got := range checks {
		if got[0] != got[1] {
			t.Fatalf("%s = %d, want %d", name, got[0], got[1])
		}
	}

	if stats.DropPct < 33.3 || stats.DropPct > 33.4 {
		t.Fatalf("syn_drop_pct = %.2f, want one of three attempts", stats.DropPct)
	}
	if stats.RTTMinUs != 10_000 || stats.RTTMaxUs != 20_000 || stats.RTTAvgUs != 15_000 {
		t.Fatalf("unexpected handshake RTTs: min=%d avg=%d max=%d", stats.RTTMinUs, stats.RTTAvgUs, stats.RTTMaxUs)
	}
}

func TestTCPHandshakeStats_UntriedAttemptsAreNotDrops(t *testing.T) {
	t.Parallel()

	hs := newTCPHandshake(4, 3)
	hs.sent(MinPort, 0, false, time.Now())

	stats := hs.stats(0)

	if stats.Unanswered != 1 || stats.DropPct != 100 {
		t.Fatalf("expected only the sent attempt to count, got unanswered=%d drop=%.1f", stats.Unanswered, stats.DropPct)
	}
}

func runSimHandshakeTrace(t *testing.T, sim *simNetwork) *TraceResult {
	t.Helper()

	opts := DefaultOptions(simTarget)
	opts.Protocol = ProtocolTCP
	opts.MaxHops = 8
	opts.ProbesPerHop = 3
	opts.ProbeInterval = time.Millisecond
	opts.Timeout = 100 * time.Millisecond
	opts.TCPSynRetries = 1
	opts.DNSResolve = false

	tracer, err := NewTracerWithResources(t.Context(), opts, logger.NewTestLogger(), TracerResources{
		Target: &TargetInfo{IP: sim.target, IPVersion: 4},
		Socket: sim,
	})
	if err != nil {
		t.Fatalf("new tracer: %v", err)
	}

	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()

	result, err := tracer.Run(ctx)
	if err != nil {
		t.Fatalf("run: %v", err)
	}

	return result
}

func TestTracerTCP_HandshakePhaseMeasuresTheTarget(t *testing.T) {
	t.Parallel()

	sim := newSimNetwork(4, "synack")
	sim.hopDelay = time.Millisecond
	sim.serverDelay = 5 * time.Millisecond

	result := runSimHandshakeTrace(t, sim)
	hs := result.TCPHandshake

	if hs == nil {
		t.Fatal("expected handshake statistics for a crafted-SYN trace")
	}
	if hs.TTL != 4 || hs.Attempts != 3 || hs.SYNSent != 3 || hs.SYNACKReceived != 3 || hs.Unanswered != 0 {
		t.Fatalf("unexpected handshake counters: %+v", hs)
	}
	if hs.DropPct != 0 || hs.Retransmits != 0 {
		t.Fatalf("expected no drops or retransmits, got %+v", hs)
	}
	if hs.ServerResponseUs == nil || *hs.ServerResponseUs < 4_000 {
		t.Fatalf("expected the server delay to show as response time, got %v", hs.ServerResponseUs)
	}
	if got := result.Hops[0].ReplyTimeExceeded; got == 0 {
		t.Fatal("expected transit hops to count Time Exceeded replies")
	}
}

func TestTracerTCP_HandshakePhaseCountsRSTsFromAClosedPort(t *testing.T) {
	t.Parallel()

	hs := runSimHandshakeTrace(t, newSimNetwork(3, "rst")).TCPHandshake

	if hs == nil || hs.RSTReceived != 3 || hs.SYNACKReceived != 0 || hs.DropPct != 0 {
		t.Fatalf("expected every handshake answered by RST, got %+v", hs)
	}
}

func TestTracerTCP_HandshakePhaseRetransmitsToASilentTarget(t *testing.T) {
	t.Parallel()

	hs := runSimHandshakeTrace(t, newSimNetwork(4, "silent")).TCPHandshake

	if hs == nil {
		t.Fatal("expected handshake statistics even when the target never answers")
	}
	if hs.TTL != 8 {
		t.Fatalf("expected an unreached trace to handshake at max_hops, got TTL %d", hs.TTL)
	}
	if hs.Unanswered != 3 || hs.DropPct != 100 || hs.Retransmits != 3 || hs.SYNSent != 6 {
		t.Fatalf("expected three unanswered handshakes with one retransmission each, got %+v", hs)
	}
}

func TestTracerTCP_ConnectFallbackReportsNoHandshake(t *testing.T) {
	t.Parallel()

	sim := newSimNetwork(4, "synack")
	sim.connectMode = true

	if hs := runSimHandshakeTrace(t, sim).TCPHandshake; hs != nil {
		t.Fatalf("expected no handshake statistics from the connect() fallback, got %+v", hs)
	}
}
