package mtr

import (
	"net"
	"testing"
)

const (
	matchTestICMPID   = 0x1234
	matchTestHop      = "192.0.2.1"
	matchTestOther    = "198.51.100.99"
	matchTestTargetV6 = "2001:db8::10"
	matchTestHopV6    = "2001:db8::1"

	typeEchoReplyV4    = 0
	typeTimeExceededV4 = 11
	typeRedirectV4     = 5
	typeEchoReplyV6    = 129
	typeTimeExceededV6 = 3
)

type matchCase struct {
	name    string
	resp    *ICMPResponse
	wantSeq int
	wantOK  bool
}

func runMatchCases(t *testing.T, tracer *Tracer, cases []matchCase) {
	t.Helper()

	for _, tc := range cases {
		seq, ok := tracer.matchProbeResponse(tc.resp)
		if ok != tc.wantOK || (tc.wantOK && seq != tc.wantSeq) {
			t.Errorf("%s: got seq=%d ok=%v, want seq=%d ok=%v", tc.name, seq, ok, tc.wantSeq, tc.wantOK)
		}
	}
}

func ipv4(s string) net.IP { return net.ParseIP(s).To4() }

func TestMatchProbeResponse_ICMP(t *testing.T) {
	t.Parallel()

	target := ipv4(simTarget)
	tracer := &Tracer{
		opts:      Options{Protocol: ProtocolICMP},
		targetIP:  target,
		ipVersion: 4,
		icmpID:    matchTestICMPID,
	}

	seq := MinPort + 5

	runMatchCases(t, tracer, []matchCase{
		{
			name:    "echo reply from the target",
			resp:    &ICMPResponse{Type: typeEchoReplyV4, SrcAddr: target, InnerID: matchTestICMPID, InnerSeq: seq},
			wantSeq: seq, wantOK: true,
		},
		{
			name:   "echo reply from another address",
			resp:   &ICMPResponse{Type: typeEchoReplyV4, SrcAddr: ipv4(matchTestOther), InnerID: matchTestICMPID, InnerSeq: seq},
			wantOK: false,
		},
		{
			name:   "echo reply for another tracer's identifier",
			resp:   &ICMPResponse{Type: typeEchoReplyV4, SrcAddr: target, InnerID: matchTestICMPID + 1, InnerSeq: seq},
			wantOK: false,
		},
		{
			name: "time exceeded quoting the probe",
			resp: &ICMPResponse{
				Type: typeTimeExceededV4, SrcAddr: ipv4(matchTestHop),
				InnerDstAddr: target, InnerID: matchTestICMPID, InnerSeq: seq,
			},
			wantSeq: seq, wantOK: true,
		},
		{
			// Some routers do not quote the Echo identifier; a zero ID is accepted.
			name: "time exceeded with an unquoted identifier",
			resp: &ICMPResponse{
				Type: typeTimeExceededV4, SrcAddr: ipv4(matchTestHop),
				InnerDstAddr: target, InnerSeq: seq,
			},
			wantSeq: seq, wantOK: true,
		},
		{
			name: "time exceeded quoting another destination",
			resp: &ICMPResponse{
				Type: typeTimeExceededV4, SrcAddr: ipv4(matchTestHop),
				InnerDstAddr: ipv4(matchTestOther), InnerID: matchTestICMPID, InnerSeq: seq,
			},
			wantOK: false,
		},
		{
			name: "time exceeded quoting another identifier",
			resp: &ICMPResponse{
				Type: typeTimeExceededV4, SrcAddr: ipv4(matchTestHop),
				InnerDstAddr: target, InnerID: matchTestICMPID + 1, InnerSeq: seq,
			},
			wantOK: false,
		},
		{
			name: "destination unreachable quoting the probe",
			resp: &ICMPResponse{
				Type: icmpv4DestUnreachableType, Code: 1, SrcAddr: ipv4(matchTestHop),
				InnerDstAddr: target, InnerID: matchTestICMPID, InnerSeq: seq,
			},
			wantSeq: seq, wantOK: true,
		},
		{
			name:   "sequence below the probe range",
			resp:   &ICMPResponse{Type: typeEchoReplyV4, SrcAddr: target, InnerID: matchTestICMPID, InnerSeq: MinPort - 1},
			wantOK: false,
		},
		{
			name: "an ICMP type that never answers a probe",
			resp: &ICMPResponse{
				Type: typeRedirectV4, SrcAddr: ipv4(matchTestHop),
				InnerDstAddr: target, InnerID: matchTestICMPID, InnerSeq: seq,
			},
			wantOK: false,
		},
	})
}

func TestMatchProbeResponse_ICMPv6(t *testing.T) {
	t.Parallel()

	target := net.ParseIP(matchTestTargetV6)
	tracer := &Tracer{
		opts:      Options{Protocol: ProtocolICMP},
		targetIP:  target,
		ipVersion: 6,
		icmpID:    matchTestICMPID,
	}

	seq := MinPort + 9

	runMatchCases(t, tracer, []matchCase{
		{
			name:    "echo reply from the target",
			resp:    &ICMPResponse{Type: typeEchoReplyV6, SrcAddr: target, InnerID: matchTestICMPID, InnerSeq: seq},
			wantSeq: seq, wantOK: true,
		},
		{
			name: "time exceeded quoting the probe",
			resp: &ICMPResponse{
				Type: typeTimeExceededV6, SrcAddr: net.ParseIP(matchTestHopV6),
				InnerDstAddr: target, InnerID: matchTestICMPID, InnerSeq: seq,
			},
			wantSeq: seq, wantOK: true,
		},
		{
			// Type 0 is an IPv4 Echo Reply; on an IPv6 trace it answers nothing.
			name:   "an IPv4 echo reply type on an IPv6 trace",
			resp:   &ICMPResponse{Type: typeEchoReplyV4, SrcAddr: target, InnerID: matchTestICMPID, InnerSeq: seq},
			wantOK: false,
		},
	})
}

func TestMatchProbeResponse_UDP(t *testing.T) {
	t.Parallel()

	target := ipv4(simTarget)
	tracer := &Tracer{
		opts:      Options{Protocol: ProtocolUDP},
		targetIP:  target,
		ipVersion: 4,
	}

	// UDP probes are keyed by their destination port, which the ICMP error
	// quotes back as InnerSeq.
	dstPort := MinPort + 17

	runMatchCases(t, tracer, []matchCase{
		{
			name: "time exceeded quoting the probe",
			resp: &ICMPResponse{
				Type: typeTimeExceededV4, SrcAddr: ipv4(matchTestHop), InnerDstAddr: target,
				InnerProto: ipProtoUDP, InnerDstPort: dstPort, InnerSeq: dstPort,
			},
			wantSeq: dstPort, wantOK: true,
		},
		{
			name: "port unreachable from the target",
			resp: &ICMPResponse{
				Type: icmpv4DestUnreachableType, Code: 3, SrcAddr: target, InnerDstAddr: target,
				InnerProto: ipProtoUDP, InnerDstPort: dstPort, InnerSeq: dstPort,
			},
			wantSeq: dstPort, wantOK: true,
		},
		{
			name: "time exceeded quoting another destination",
			resp: &ICMPResponse{
				Type: typeTimeExceededV4, SrcAddr: ipv4(matchTestHop), InnerDstAddr: ipv4(matchTestOther),
				InnerProto: ipProtoUDP, InnerDstPort: dstPort, InnerSeq: dstPort,
			},
			wantOK: false,
		},
		{
			name: "quoted destination port below the probe range",
			resp: &ICMPResponse{
				Type: typeTimeExceededV4, SrcAddr: ipv4(matchTestHop), InnerDstAddr: target,
				InnerProto: ipProtoUDP, InnerDstPort: 53, InnerSeq: 53,
			},
			wantOK: false,
		},
		{
			// An echo reply quotes no datagram, so it cannot answer a UDP probe.
			name:   "echo reply on a UDP trace",
			resp:   &ICMPResponse{Type: typeEchoReplyV4, SrcAddr: target, InnerSeq: dstPort},
			wantOK: false,
		},
	})
}
