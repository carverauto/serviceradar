package agent

import (
	"net"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
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

// netprobe's collector_ip must come from getSourceIP(), never from
// config.HostIP. `host_ip` in agent.json is an onboard-time pin, and a re-IP'd
// host leaves it pointing at an address no longer on any local interface.
//
// This drives stampCollectorIP -- the function the config path actually calls --
// so reverting it to the raw pin fails HERE. Testing getSourceIP() alone would
// not: that helper is not what the regression would change.
//
// The failure being guarded is silent in production. netprobe stamps the stale
// address as the subject of every process snapshot, core matches it against no
// device, and the enrichment-only rule correctly drops the payload -- so nothing
// errors, nothing warns, and serviceradar.netprobe.process.v1 simply never
// arrives. Observed on a lab host pinned to 192.168.2.243 while its interface
// held 192.168.1.171.
func TestStampCollectorIPIgnoresAPinThatIsNotOnAnyLocalInterface(t *testing.T) {
	localIPs, err := localSourceIPs()
	if err != nil || len(localIPs) == 0 {
		t.Skip("no enumerable local interfaces; getSourceIP legitimately falls back to the pin")
	}

	// TEST-NET-3 (RFC 5737): reserved for documentation, so it cannot be a real
	// local address on the machine running this test.
	const stalePin = "203.0.113.9"

	pl := NewPushLoop(&Server{config: &ServerConfig{HostIP: stalePin}}, nil, 0, logger.NewTestLogger())
	cfg := &netprobepb.VisibilityAgentConfig{}

	pl.stampCollectorIP(cfg)

	if cfg.GetCollectorIp() == stalePin {
		t.Fatalf("collector_ip was stamped with the stale pin %q; netprobe would label every DPI subject and process snapshot with an address this host does not hold", stalePin)
	}

	if cfg.GetCollectorIp() == "" {
		t.Fatal("collector_ip was left empty; netprobe treats that as \"cannot name a subject\" and stops serving the process schema entirely")
	}
}

// A nil config must not panic: applyVisibilityConfig reaches this with whatever
// the gateway parse produced.
func TestStampCollectorIPToleratesNilConfig(t *testing.T) {
	pl := NewPushLoop(&Server{config: &ServerConfig{}}, nil, 0, logger.NewTestLogger())

	pl.stampCollectorIP(nil)
}
