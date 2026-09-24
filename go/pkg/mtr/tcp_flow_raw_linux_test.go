package mtr

import (
	"bytes"
	"encoding/binary"
	"net"
	"syscall"
	"testing"
	"time"
)

func testRawFlow() *rawTCPFlow {
	return &rawTCPFlow{
		src:     net.ParseIP("192.0.2.1").To4(),
		dst:     net.ParseIP("198.51.100.10").To4(),
		srcPort: 40001,
		dstPort: 443,
		isnBase: 0xFFFF0000, // exercises sequence wrap-around
	}
}

// ipv4TCPPacket builds what an IPv4 raw TCP socket delivers: an IP header
// followed by the TCP header.
func ipv4TCPPacket(src net.IP, srcPort, dstPort int, ack uint32, flags byte) []byte {
	pkt := make([]byte, ipv4HeaderMinLen+tcpHeaderMinLen)
	pkt[0] = 0x45
	pkt[9] = ipProtoTCP
	copy(pkt[12:16], src.To4())

	seg := pkt[ipv4HeaderMinLen:]
	binary.BigEndian.PutUint16(seg[0:2], uint16(srcPort))
	binary.BigEndian.PutUint16(seg[2:4], uint16(dstPort))
	binary.BigEndian.PutUint32(seg[8:12], ack)
	seg[13] = flags

	return pkt
}

func TestRawTCPFlow_ParseCreditsTheAcknowledgedProbe(t *testing.T) {
	t.Parallel()

	flow := testRawFlow()
	seq := MinPort + 7
	ack := flow.isnBase + uint32(seq) + 1

	reply, ok := flow.parse(ipv4TCPPacket(flow.dst, 443, 40001, ack, tcpFlagSYN|tcpFlagACK), nil, time.Now())
	if !ok || reply.Seq != seq || !reply.SYNACK || reply.RST {
		t.Fatalf("expected a SYN-ACK for probe %d, got %+v ok=%v", seq, reply, ok)
	}

	reply, ok = flow.parse(ipv4TCPPacket(flow.dst, 443, 40001, ack, tcpFlagRST|tcpFlagACK), nil, time.Now())
	if !ok || reply.Seq != seq || !reply.RST {
		t.Fatalf("expected an RST for probe %d, got %+v ok=%v", seq, reply, ok)
	}
}

func TestRawTCPFlow_ParseRejectsSegmentsOffTheFlow(t *testing.T) {
	t.Parallel()

	flow := testRawFlow()
	ack := flow.isnBase + uint32(MinPort) + 1
	other := net.ParseIP("198.51.100.99")

	cases := map[string][]byte{
		"other source":      ipv4TCPPacket(other, 443, 40001, ack, tcpFlagSYN|tcpFlagACK),
		"other remote port": ipv4TCPPacket(flow.dst, 80, 40001, ack, tcpFlagSYN|tcpFlagACK),
		"other local port":  ipv4TCPPacket(flow.dst, 443, 40002, ack, tcpFlagSYN|tcpFlagACK),
		"not an answer":     ipv4TCPPacket(flow.dst, 443, 40001, ack, tcpFlagACK),
	}

	for name, pkt := range cases {
		if _, ok := flow.parse(pkt, nil, time.Now()); ok {
			t.Fatalf("%s: expected the segment to be dropped", name)
		}
	}
}

func TestRawTCPFlow_UnknownAckIsAMismatchNotAProbe(t *testing.T) {
	t.Parallel()

	flow := testRawFlow()

	reply, ok := flow.parse(ipv4TCPPacket(flow.dst, 443, 40001, 12345, tcpFlagSYN|tcpFlagACK), nil, time.Now())
	if !ok || reply.Seq != -1 {
		t.Fatalf("expected an acknowledgement mismatch (seq -1), got %+v ok=%v", reply, ok)
	}
}

func TestRawTCPFlow_MatchQuotedUsesSequenceOnTheFlow(t *testing.T) {
	t.Parallel()

	flow := testRawFlow()
	seq := MinPort + 42

	resp := &ICMPResponse{
		InnerProto:   ipProtoTCP,
		InnerSrcPort: flow.srcPort,
		InnerDstPort: flow.dstPort,
		InnerTCPSeq:  flow.isnBase + uint32(seq),
	}

	if got, ok := flow.MatchQuoted(resp); !ok || got != seq {
		t.Fatalf("expected quoted probe %d, got %d ok=%v", seq, got, ok)
	}

	resp.InnerSrcPort = flow.srcPort + 1
	if _, ok := flow.MatchQuoted(resp); ok {
		t.Fatal("expected a quote from another flow's source port to be ignored")
	}
}

func TestRawTCPFlow_IPv6ReadUsesSockaddrSource(t *testing.T) {
	t.Parallel()

	seg := make([]byte, tcpHeaderMinLen)
	from := &syscall.SockaddrInet6{}
	copy(from.Addr[:], net.ParseIP("2001:db8::10"))

	got, src, ok := splitRawTCP(seg, from, true)
	if !ok || len(got) != tcpHeaderMinLen || !src.Equal(net.ParseIP("2001:db8::10")) {
		t.Fatalf("unexpected IPv6 split: len=%d src=%v ok=%v", len(got), src, ok)
	}
}

// Every probe of a raw TCP flow, whichever TTL it is sent at, carries the same
// addresses and ports; only the sequence number (and the checksum covering it)
// changes. That is what keeps ECMP from hashing successive TTLs onto different
// paths.
func TestRawTCPFlow_EveryProbeSharesTheFlowFiveTuple(t *testing.T) {
	t.Parallel()

	ipv6Flow := testRawFlow()
	ipv6Flow.ipv6 = true
	ipv6Flow.src = net.ParseIP("2001:db8::1")
	ipv6Flow.dst = net.ParseIP("2001:db8::10")

	for name, flow := range map[string]*rawTCPFlow{"ipv4": testRawFlow(), "ipv6": ipv6Flow} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			var first []byte

			// One probe per TTL, as sendProbes allocates them: TTL n gets the next seq.
			for ttl := 1; ttl <= 6; ttl++ {
				seq := MinPort + ttl - 1
				seg := append([]byte(nil), flow.synSegment(seq)...)

				if got := int(binary.BigEndian.Uint16(seg[0:2])); got != flow.srcPort {
					t.Fatalf("TTL %d: source port %d, want the reserved %d", ttl, got, flow.srcPort)
				}
				if got := int(binary.BigEndian.Uint16(seg[2:4])); got != flow.dstPort {
					t.Fatalf("TTL %d: destination port %d, want %d", ttl, got, flow.dstPort)
				}
				if got := binary.BigEndian.Uint32(seg[4:8]); got != flow.isnBase+uint32(seq) { //nolint:gosec
					t.Fatalf("TTL %d: sequence %#x, want isn base + %d", ttl, got, seq)
				}
				// The checksum only verifies over the flow's own pseudo-header
				// addresses, so this also pins the source and destination.
				if got := tcpChecksum(flow.src, flow.dst, seg); got != 0 {
					t.Fatalf("TTL %d: checksum does not verify for the flow's addresses: %#x", ttl, got)
				}

				masked := append([]byte(nil), seg...)
				clear(masked[4:8])
				clear(masked[16:18])

				if first == nil {
					first = masked
				} else if !bytes.Equal(masked, first) {
					t.Fatalf("TTL %d: SYN differs outside the sequence number:\n got % x\nwant % x", ttl, masked, first)
				}
			}
		})
	}
}
