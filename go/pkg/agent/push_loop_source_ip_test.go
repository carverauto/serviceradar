package agent

import (
	"net"
	"testing"
)

func TestSelectSourceIPKeepsConfiguredAddressWhenStillLocal(t *testing.T) {
	t.Parallel()

	got := selectSourceIP("192.168.2.243", []net.IP{
		net.ParseIP("10.0.0.5"),
		net.ParseIP("192.168.2.243"),
	})
	if got != "192.168.2.243" {
		t.Fatalf("selectSourceIP() = %q, want pinned local address", got)
	}
}

func TestSelectSourceIPIgnoresStaleConfiguredAddressAfterMove(t *testing.T) {
	t.Parallel()

	got := selectSourceIP("192.168.2.243", []net.IP{
		net.ParseIP("192.168.1.171"),
		net.ParseIP("fe80::1"),
	})
	if got != "192.168.1.171" {
		t.Fatalf("selectSourceIP() = %q, want live address after network move", got)
	}
}

func TestSelectSourceIPFallsBackToConfiguredWhenNoLocalAddress(t *testing.T) {
	t.Parallel()

	got := selectSourceIP("203.0.113.10", nil)
	if got != "203.0.113.10" {
		t.Fatalf("selectSourceIP() = %q, want configured fallback", got)
	}
}

func TestSelectSourceIPPrefersPrivateIPv4WhenUnconfigured(t *testing.T) {
	t.Parallel()

	got := selectSourceIP("", []net.IP{
		net.ParseIP("2001:db8::10"),
		net.ParseIP("203.0.113.8"),
		net.ParseIP("192.168.1.171"),
	})
	if got != "192.168.1.171" {
		t.Fatalf("selectSourceIP() = %q, want private IPv4", got)
	}
}
