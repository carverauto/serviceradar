package mtr

import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestBuildTCPSyn_HeaderAndChecksum(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		src  net.IP
		dst  net.IP
		mss  uint16
	}{
		{name: "ipv4", src: net.ParseIP("192.0.2.1").To4(), dst: net.ParseIP("198.51.100.10").To4(), mss: 1460},
		{name: "ipv6", src: net.ParseIP("2001:db8::1"), dst: net.ParseIP("2001:db8::10"), mss: 1440},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			seg := buildTCPSyn(nil, tc.src, tc.dst, 40001, 443, 0xDEADBEEF)

			if len(seg) != tcpSynLen {
				t.Fatalf("expected %d-byte SYN, got %d", tcpSynLen, len(seg))
			}
			if got := binary.BigEndian.Uint16(seg[0:2]); got != 40001 {
				t.Fatalf("source port = %d", got)
			}
			if got := binary.BigEndian.Uint16(seg[2:4]); got != 443 {
				t.Fatalf("destination port = %d", got)
			}
			if got := binary.BigEndian.Uint32(seg[4:8]); got != 0xDEADBEEF {
				t.Fatalf("sequence = %#x", got)
			}
			if seg[12]>>4 != tcpSynLen/4 {
				t.Fatalf("data offset = %d words", seg[12]>>4)
			}
			if seg[13] != tcpFlagSYN {
				t.Fatalf("flags = %#x, want SYN only", seg[13])
			}
			if seg[20] != 2 || seg[21] != 4 || binary.BigEndian.Uint16(seg[22:24]) != tc.mss {
				t.Fatalf("MSS option = % x", seg[20:24])
			}

			// A correct Internet checksum makes the sum over the pseudo-header
			// and the checksummed segment fold to zero.
			if got := tcpChecksum(tc.src, tc.dst, seg); got != 0 {
				t.Fatalf("checksum does not verify: residual %#x", got)
			}
		})
	}
}

func TestParseTCPSegment_ProbeAnswers(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		flags  byte
		answer bool
	}{
		{name: "syn-ack", flags: tcpFlagSYN | tcpFlagACK, answer: true},
		{name: "rst", flags: tcpFlagRST, answer: true},
		{name: "rst-ack", flags: tcpFlagRST | tcpFlagACK, answer: true},
		{name: "syn-only", flags: tcpFlagSYN, answer: false},
		{name: "ack-only", flags: tcpFlagACK, answer: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			raw := make([]byte, tcpHeaderMinLen)
			binary.BigEndian.PutUint16(raw[0:2], 443)
			binary.BigEndian.PutUint16(raw[2:4], 40001)
			binary.BigEndian.PutUint32(raw[8:12], 0x01020304)
			raw[13] = tc.flags

			seg, ok := parseTCPSegment(raw)
			if !ok {
				t.Fatal("expected segment to parse")
			}
			if seg.srcPort != 443 || seg.dstPort != 40001 || seg.ack != 0x01020304 {
				t.Fatalf("unexpected header fields: %+v", seg)
			}
			if got := seg.isProbeAnswer(); got != tc.answer {
				t.Fatalf("isProbeAnswer = %v, want %v", got, tc.answer)
			}
		})
	}

	if _, ok := parseTCPSegment(make([]byte, tcpHeaderMinLen-1)); ok {
		t.Fatal("expected a truncated header to be rejected")
	}
}

func TestParseQuotedTransport_TCPCarriesPortsAndSequence(t *testing.T) {
	t.Parallel()

	quoted := make([]byte, 8)
	binary.BigEndian.PutUint16(quoted[0:2], 40001)
	binary.BigEndian.PutUint16(quoted[2:4], 443)
	binary.BigEndian.PutUint32(quoted[4:8], 0xCAFEF00D)

	resp := &ICMPResponse{}
	parseQuotedTransport(resp, ipProtoTCP, quoted)

	if resp.InnerProto != ipProtoTCP || resp.InnerSrcPort != 40001 || resp.InnerDstPort != 443 {
		t.Fatalf("unexpected quoted ports: %+v", resp)
	}
	if resp.InnerTCPSeq != 0xCAFEF00D {
		t.Fatalf("quoted sequence = %#x", resp.InnerTCPSeq)
	}

	// Only 4 quoted bytes: ports are readable, the sequence is not.
	short := &ICMPResponse{}
	parseQuotedTransport(short, ipProtoTCP, quoted[:4])

	if short.InnerDstPort != 443 || short.InnerTCPSeq != 0 {
		t.Fatalf("unexpected fields from a 4-byte quote: %+v", short)
	}
}

// simNetwork is a fake RawSocket whose TCP flow answers like a path of
// pathLen hops: routers below pathLen return Time Exceeded, and the hop at
// pathLen (and beyond) answers according to mode.
type simNetwork struct {
	target  net.IP
	pathLen int
	mode    string // "synack", "rst", "silent", "unreachable"
	sendErr error
	openErr error

	// sendCalls counts SendSYN calls; failSendAfter makes every call after
	// that many fail, so a test can fail only the handshake phase.
	sendCalls     int
	failSendAfter int

	// hopDelay is added per TTL to reply times and serverDelay on top for the
	// target's own answers; connectMode makes the flow report Crafted() false.
	hopDelay    time.Duration
	serverDelay time.Duration
	connectMode bool

	icmp chan *ICMPResponse
	flow *simTCPFlow
}

var (
	errSimSend  = errors.New("simulated send failure")
	errSimRoute = errors.New("simulated route failure")
)

const simTarget = "198.51.100.10"

func newSimNetwork(pathLen int, mode string) *simNetwork {
	return &simNetwork{
		target:  net.ParseIP(simTarget).To4(),
		pathLen: pathLen,
		mode:    mode,
		icmp:    make(chan *ICMPResponse, 256),
	}
}

func (s *simNetwork) SendICMP(_ net.IP, _ int, _ int, _ int, _ []byte) error { return nil }
func (s *simNetwork) SendUDP(_ net.IP, _ int, _ int, _ int, _ []byte) error  { return nil }
func (s *simNetwork) Close() error                                           { return nil }
func (s *simNetwork) IsIPv6() bool                                           { return false }

func (s *simNetwork) OpenTCPFlow(_ net.IP, _ int, _ time.Duration) (TCPFlow, error) {
	if s.openErr != nil {
		return nil, s.openErr
	}

	s.flow = &simTCPFlow{net: s, replies: make(chan *TCPReply, 256)}

	return s.flow, nil
}

func (s *simNetwork) Receive(deadline time.Time) (*ICMPResponse, error) {
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()

	select {
	case resp := <-s.icmp:
		return resp, nil
	case <-timer.C:
		return nil, fakeTimeoutError{}
	}
}

type simTCPFlow struct {
	net     *simNetwork
	replies chan *TCPReply
}

const (
	simSrcPort = 40001
	simDstPort = 443
)

func (f *simTCPFlow) SendSYN(ttl, seq int) error {
	if f.net.sendErr != nil {
		return f.net.sendErr
	}

	f.net.sendCalls++
	if f.net.failSendAfter > 0 && f.net.sendCalls > f.net.failSendAfter {
		return errSimSend
	}

	now := time.Now().Add(time.Duration(min(ttl, f.net.pathLen)) * f.net.hopDelay)
	answered := now.Add(f.net.serverDelay)

	switch {
	case ttl < f.net.pathLen:
		f.net.icmp <- f.quotedError(net.IPv4(192, 0, 2, byte(ttl)), 11, 0, seq, now)
	case f.net.mode == "synack":
		f.replies <- &TCPReply{Seq: seq, SYNACK: true, RecvTime: answered}
	case f.net.mode == "rst":
		f.replies <- &TCPReply{Seq: seq, RST: true, RecvTime: answered}
	case f.net.mode == "unreachable":
		// A firewall at the last hop answers "administratively prohibited".
		f.net.icmp <- f.quotedError(net.IPv4(192, 0, 2, byte(ttl)), 3, 13, seq, now)
	}

	return nil
}

func (f *simTCPFlow) quotedError(from net.IP, icmpType, code, seq int, now time.Time) *ICMPResponse {
	return &ICMPResponse{
		SrcAddr:      from.To4(),
		Type:         icmpType,
		Code:         code,
		InnerDstAddr: f.net.target,
		InnerProto:   ipProtoTCP,
		InnerSrcPort: simSrcPort,
		InnerDstPort: simDstPort,
		InnerTCPSeq:  uint32(seq), //nolint:gosec
		RecvTime:     now,
	}
}

func (f *simTCPFlow) Receive(deadline time.Time) (*TCPReply, error) {
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()

	select {
	case reply := <-f.replies:
		return reply, nil
	case <-timer.C:
		return nil, probeTimeoutError{}
	}
}

func (f *simTCPFlow) MatchQuoted(resp *ICMPResponse) (int, bool) {
	if resp.InnerProto != ipProtoTCP || resp.InnerSrcPort != simSrcPort || resp.InnerDstPort != simDstPort {
		return 0, false
	}

	return int(resp.InnerTCPSeq), true
}

func (f *simTCPFlow) Crafted() bool { return !f.net.connectMode }
func (f *simTCPFlow) Close() error  { return nil }

func runSimTCPTrace(t *testing.T, sim *simNetwork, maxHops int) (*TraceResult, error) {
	t.Helper()

	opts := DefaultOptions(sim.target.String())
	opts.Protocol = ProtocolTCP
	opts.MaxHops = maxHops
	opts.ProbesPerHop = 1
	opts.ProbeInterval = time.Millisecond
	opts.Timeout = 150 * time.Millisecond
	opts.MaxUnknownHops = maxHops + 1
	opts.DNSResolve = false

	tracer, err := NewTracerWithResources(t.Context(), opts, logger.NewTestLogger(), TracerResources{
		Target: &TargetInfo{IP: sim.target, IPVersion: 4},
		Socket: sim,
	})
	if err != nil {
		t.Fatalf("new tracer: %v", err)
	}

	ctx, cancel := context.WithTimeout(t.Context(), 400*time.Millisecond)
	defer cancel()

	return tracer.Run(ctx)
}

func TestTracerTCP_SynAckMarksTargetReachedAtItsTTL(t *testing.T) {
	t.Parallel()

	result, err := runSimTCPTrace(t, newSimNetwork(4, "synack"), 8)
	if err != nil {
		t.Fatalf("run: %v", err)
	}

	if !result.TargetReached {
		t.Fatal("expected a SYN-ACK from the target to mark it reached")
	}
	if result.TotalHops != 4 || result.LastRespondingHop != 4 {
		t.Fatalf("expected the path to end at hop 4, got total=%d last_responding=%d",
			result.TotalHops, result.LastRespondingHop)
	}
	if got := result.Hops[3].Addr; got != "198.51.100.10" {
		t.Fatalf("expected hop 4 to be the target, got %q", got)
	}
	if result.TCPPort != DefaultTCPPort {
		t.Fatalf("expected the TCP port to be reported, got %d", result.TCPPort)
	}
	if result.TCPProbeMode != tcpProbeModeSyn {
		t.Fatalf("expected the crafted-SYN probe mode, got %q", result.TCPProbeMode)
	}
	if result.Hops[3].ReplySynack != 1 || result.Hops[3].ReplyRst != 0 {
		t.Fatalf("expected the target hop to count one SYN-ACK, got synack=%d rst=%d",
			result.Hops[3].ReplySynack, result.Hops[3].ReplyRst)
	}
}

func TestTracer_StopsProbingPastTheTargetOnceItAnswers(t *testing.T) {
	t.Parallel()

	sim := newSimNetwork(3, "synack")

	opts := DefaultOptions(simTarget)
	opts.Protocol = ProtocolTCP
	opts.MaxHops = 20
	opts.ProbesPerHop = 1
	opts.ProbeInterval = 20 * time.Millisecond // longer than the simulated RTT
	opts.Timeout = 150 * time.Millisecond
	opts.DNSResolve = false

	tracer, err := NewTracerWithResources(t.Context(), opts, logger.NewTestLogger(), TracerResources{
		Target: &TargetInfo{IP: sim.target, IPVersion: 4},
		Socket: sim,
	})
	if err != nil {
		t.Fatalf("new tracer: %v", err)
	}

	result, err := tracer.Run(t.Context())
	if err != nil {
		t.Fatalf("run: %v", err)
	}

	if !result.TargetReached || result.TotalHops != 3 {
		t.Fatalf("expected the target at hop 3, got reached=%v total=%d", result.TargetReached, result.TotalHops)
	}

	// The reply for TTL 3 lands during the probe interval that follows it, so
	// at most one probe past the target (TTL 4) may already have been sent.
	if result.ProbedHops > 4 {
		t.Fatalf("expected probing to stop just past the target, probed to hop %d", result.ProbedHops)
	}
}

func TestTracerTCP_RSTMarksTargetReached(t *testing.T) {
	t.Parallel()

	result, err := runSimTCPTrace(t, newSimNetwork(3, "rst"), 8)
	if err != nil {
		t.Fatalf("run: %v", err)
	}

	if !result.TargetReached || result.TotalHops != 3 {
		t.Fatalf("expected an RST from the target to end the path at hop 3, got reached=%v total=%d",
			result.TargetReached, result.TotalHops)
	}
	if result.TCPProbeMode != tcpProbeModeSyn {
		t.Fatalf("expected the crafted-SYN probe mode, got %q", result.TCPProbeMode)
	}
	if result.Hops[2].ReplyRst != 1 || result.Hops[2].ReplySynack != 0 {
		t.Fatalf("expected the target hop to count one RST, got synack=%d rst=%d",
			result.Hops[2].ReplySynack, result.Hops[2].ReplyRst)
	}
}

func TestTracerTCP_SilentTargetReportsProbedDepthSeparately(t *testing.T) {
	t.Parallel()

	result, err := runSimTCPTrace(t, newSimNetwork(4, "silent"), 8)
	if err != nil {
		t.Fatalf("run: %v", err)
	}

	if result.TargetReached {
		t.Fatal("expected a silent target not to be reached")
	}
	if result.ProbedHops != 8 {
		t.Fatalf("expected probing to reach max_hops 8, got %d", result.ProbedHops)
	}
	if result.LastRespondingHop != 3 {
		t.Fatalf("expected the last reply at hop 3, got %d", result.LastRespondingHop)
	}
}

func TestTracerTCP_UnreachableCodeRecordedOnAnsweringHop(t *testing.T) {
	t.Parallel()

	result, err := runSimTCPTrace(t, newSimNetwork(4, "unreachable"), 5)
	if err != nil {
		t.Fatalf("run: %v", err)
	}

	hop := result.Hops[3]
	if hop.UnreachableCode == nil || *hop.UnreachableCode != 13 {
		t.Fatalf("expected hop 4 to record unreachable code 13, got %v", hop.UnreachableCode)
	}
	if result.Hops[0].UnreachableCode != nil {
		t.Fatal("expected Time Exceeded hops to carry no unreachable code")
	}
}

func TestTracerTCP_EverySendFailingIsAnError(t *testing.T) {
	t.Parallel()

	sim := newSimNetwork(4, "synack")
	sim.sendErr = errSimSend

	_, err := runSimTCPTrace(t, sim, 4)
	if !errors.Is(err, errNoProbesSent) || !errors.Is(err, sim.sendErr) {
		t.Fatalf("expected a no-probes-sent error wrapping the send failure, got %v", err)
	}
}

func TestTracerTCP_FlowOpenFailureIsAnError(t *testing.T) {
	t.Parallel()

	sim := newSimNetwork(4, "synack")
	sim.openErr = errSimRoute

	if _, err := runSimTCPTrace(t, sim, 4); !errors.Is(err, sim.openErr) {
		t.Fatalf("expected the flow open failure to be returned, got %v", err)
	}
}

func TestTracerTCP_IgnoresQuotedHeadersForOtherDestinations(t *testing.T) {
	t.Parallel()

	sim := newSimNetwork(4, "synack")
	flow, _ := sim.OpenTCPFlow(nil, 0, 0)

	tracer := &Tracer{
		opts:      Options{Protocol: ProtocolTCP},
		targetIP:  sim.target,
		ipVersion: 4,
		tcpFlow:   flow,
	}

	resp := sim.flow.quotedError(net.IPv4(192, 0, 2, 1), 11, 0, MinPort, time.Now())
	if _, ok := tracer.matchProbeResponse(resp); !ok {
		t.Fatal("expected the trace's own quoted SYN to match")
	}

	resp.InnerDstAddr = net.ParseIP("198.51.100.99").To4()
	if _, ok := tracer.matchProbeResponse(resp); ok {
		t.Fatal("expected a quoted SYN toward another destination to be ignored")
	}
}
