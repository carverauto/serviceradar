//go:build linux || darwin

package mtr

import (
	"errors"
	"net"
	"testing"
	"time"
)

// A TCP flow toward a zone-less IPv6 link-local address must fail with a clear
// error before any socket is opened, instead of the EINVAL the kernel returns
// once a socket is aimed at it. None of these cases touches the network: the
// connect() flow opens no socket until SendSYN, and the rejection comes first.
func TestNewConnectTCPFlow_RejectsLinkLocalIPv6(t *testing.T) {
	t.Parallel()

	flow, err := newConnectTCPFlow(net.ParseIP("fe80::1"), 443, time.Second, true)
	if !errors.Is(err, errLinkLocalTCPTarget) {
		t.Fatalf("err = %v, want %v", err, errLinkLocalTCPTarget)
	}

	if flow != nil {
		t.Fatalf("flow = %#v, want nil", flow)
	}
}

func TestNewConnectTCPFlow_AcceptsRoutableTargets(t *testing.T) {
	t.Parallel()

	// IPv4 link-local stays accepted: it needs no zone, so the kernel can route
	// it on-link, and whether it is worth tracing is a selection decision.
	for _, target := range []string{"fd00::10", "2001:db8::10", "192.0.2.10", "169.254.0.10"} {
		ip := net.ParseIP(target)

		flow, err := newConnectTCPFlow(ip, 443, time.Second, ip.To4() == nil)
		if err != nil {
			t.Fatalf("%s: unexpected error %v", target, err)
		}

		_ = flow.Close()
	}
}

// OpenTCPFlow must return a nil TCPFlow, not an interface wrapping a nil
// *connectTCPFlow, when the connect() fallback rejects the target. A negative
// send descriptor selects that fallback on every platform.
func TestOpenTCPFlow_ConnectFallbackRejectsLinkLocalIPv6(t *testing.T) {
	t.Parallel()

	flow, err := newTestRawSocket(-1).OpenTCPFlow(net.ParseIP("fe80::1"), 443, time.Second)
	if !errors.Is(err, errLinkLocalTCPTarget) {
		t.Fatalf("err = %v, want %v", err, errLinkLocalTCPTarget)
	}

	if flow != nil {
		t.Fatalf("flow = %#v, want nil", flow)
	}
}

func TestCheckTCPFlowTarget(t *testing.T) {
	t.Parallel()

	cases := map[string]bool{
		"fe80::1":      true,
		"febf::1":      true, // last /16 inside fe80::/10
		"fec0::1":      false,
		"fd00::10":     false,
		"2001:db8::10": false,
		"192.0.2.10":   false,
		"169.254.0.10": false,
	}

	for target, rejected := range cases {
		err := checkTCPFlowTarget(net.ParseIP(target))
		if got := errors.Is(err, errLinkLocalTCPTarget); got != rejected {
			t.Errorf("%s: rejected = %v (err %v), want %v", target, got, err, rejected)
		}
	}
}
