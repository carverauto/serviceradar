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
	hs.reserve(MinPort, 0, start)
	hs.confirm(MinPort)
	hs.record(&TCPReply{Seq: MinPort, SYNACK: true, RecvTime: start.Add(10 * time.Millisecond)})
	hs.record(&TCPReply{Seq: MinPort, SYNACK: true, RecvTime: start.Add(30 * time.Millisecond)})

	// Attempt 1: lost, answered only after a retransmission, with an RST.
	hs.reserve(MinPort+1, 1, start)
	hs.confirm(MinPort + 1)
	hs.reserve(MinPort+3, 1, start.Add(100*time.Millisecond))
	hs.confirm(MinPort + 3)
	hs.record(&TCPReply{Seq: MinPort + 3, RST: true, RecvTime: start.Add(120 * time.Millisecond)})

	// Attempt 2: never answered.
	hs.reserve(MinPort+2, 2, start)
	hs.confirm(MinPort + 2)
	hs.reserve(MinPort+4, 2, start.Add(100*time.Millisecond))
	hs.confirm(MinPort + 4)

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
	hs.reserve(MinPort, 0, time.Now())
	hs.confirm(MinPort)

	stats := hs.stats(0)

	if stats.Unanswered != 1 || stats.DropPct != 100 {
		t.Fatalf("expected only the sent attempt to count, got unanswered=%d drop=%.1f", stats.Unanswered, stats.DropPct)
	}
}

func TestTCPHandshakeStats_ReplyBeforeConfirmIsCredited(t *testing.T) {
	t.Parallel()

	start := time.Now()
	hs := newTCPHandshake(9, 1)

	// The target answers while the sender is still between writing the SYN and
	// confirming it; the reserved sequence must still take the reply.
	hs.reserve(MinPort, 0, start)

	if !hs.record(&TCPReply{Seq: MinPort, SYNACK: true, RecvTime: start.Add(5 * time.Millisecond)}) {
		t.Fatal("expected a reply to a reserved sequence to be credited")
	}

	hs.confirm(MinPort)

	stats := hs.stats(0)
	if stats.SYNSent != 1 || stats.SYNACKReceived != 1 || stats.Unanswered != 0 || stats.DropPct != 0 {
		t.Fatalf("a reply to a reserved sequence must count as answered: %+v", stats)
	}
}

func TestTCPHandshakeStats_ReleasedSendIsNotCounted(t *testing.T) {
	t.Parallel()

	hs := newTCPHandshake(4, 1)
	hs.reserve(MinPort, 0, time.Now())
	hs.release(MinPort)

	stats := hs.stats(0)
	if stats.SYNSent != 0 || stats.Unanswered != 0 || stats.DropPct != 0 {
		t.Fatalf("a released send must not count as a try or a drop: %+v", stats)
	}

	if hs.record(&TCPReply{Seq: MinPort, SYNACK: true, RecvTime: time.Now()}) {
		t.Fatal("a released sequence must not credit a reply")
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

func TestTracerTCP_HandshakeSendFailureIsNotADrop(t *testing.T) {
	t.Parallel()

	sim := newSimNetwork(4, "synack")

	opts := DefaultOptions(simTarget)
	opts.Protocol = ProtocolTCP
	opts.MaxHops = 4
	opts.ProbesPerHop = 1
	opts.ProbeInterval = time.Millisecond
	opts.Timeout = 100 * time.Millisecond
	opts.TCPSynRetries = 1
	opts.DNSResolve = false

	// Path probing reaches the target in MaxHops sends; every handshake SYN
	// after those succeeds-to-send path probes fails to leave the host.
	sim.failSendAfter = opts.MaxHops

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
	if !result.TargetReached {
		t.Fatal("expected path probing to succeed before the handshake failures")
	}

	hs := result.TCPHandshake
	if hs == nil {
		t.Fatal("expected handshake statistics for a crafted-SYN trace")
	}
	if hs.Attempts != 1 {
		t.Fatalf("expected one handshake attempt, got %d", hs.Attempts)
	}
	if hs.SYNSent != 0 || hs.Unanswered != 0 || hs.Retransmits != 0 || hs.DropPct != 0 {
		t.Fatalf("failed handshake sends must not count as tries or drops: %+v", hs)
	}
}

func TestTracerTCP_HandshakeFirstSendAfterFailureIsNotARetransmit(t *testing.T) {
	t.Parallel()

	sim := newSimNetwork(4, "synack")

	opts := DefaultOptions(simTarget)
	opts.Protocol = ProtocolTCP
	opts.MaxHops = 4
	opts.ProbesPerHop = 1
	opts.ProbeInterval = time.Millisecond
	opts.Timeout = 100 * time.Millisecond
	opts.TCPSynRetries = 1
	opts.DNSResolve = false

	// Path probing reaches the target in MaxHops sends; the first handshake
	// send then fails locally, and the next round's send succeeds and answers.
	sim.failSendAt = opts.MaxHops + 1

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
	if !result.TargetReached {
		t.Fatal("expected path probing to succeed before the handshake send failure")
	}

	hs := result.TCPHandshake
	if hs == nil {
		t.Fatal("expected handshake statistics for a crafted-SYN trace")
	}
	if hs.Attempts != 1 || hs.SYNSent != 1 || hs.Unanswered != 0 || hs.DropPct != 0 {
		t.Fatalf("unexpected handshake counters: %+v", hs)
	}
	if hs.Retransmits != 0 || hs.AnsweredAfterRetx != 0 {
		t.Fatalf("a first SYN after local send failures is not a retransmit: %+v", hs)
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
