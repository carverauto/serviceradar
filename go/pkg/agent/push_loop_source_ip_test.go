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

func TestSelectSourceIPSkipsDockerBridgeAndOverlayInterfacesWhenFallingBack(t *testing.T) {
	t.Parallel()

	const hostNICIP = "192.0.2.20"

	if got := selectSourceIP("", []net.IP{
		net.ParseIP("172.17.0.1"),
		net.ParseIP(hostNICIP),
	}); got != hostNICIP {
		t.Fatalf("selectSourceIP() = %q, want 192.0.2.20 instead of docker0 default bridge", got)
	}

	if got := selectSourceIP("172.17.0.1", []net.IP{
		net.ParseIP("172.17.0.1"),
		net.ParseIP(hostNICIP),
	}); got != "172.17.0.1" {
		t.Fatalf("selectSourceIP(configured) = %q, want configured host_ip 172.17.0.1", got)
	}

	mustInterface := func(name, mac, cidr string) hostInterface {
		t.Helper()
		hardware, err := net.ParseMAC(mac)
		if err != nil {
			t.Fatal(err)
		}
		ip, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			t.Fatal(err)
		}
		ipNet.IP = ip
		return hostInterface{
			Interface: net.Interface{Name: name, HardwareAddr: hardware, Flags: net.FlagUp},
			Addrs:     []net.Addr{ipNet},
		}
	}

	interfaces := []hostInterface{
		mustInterface("docker0", "02:42:00:00:00:01", "172.17.0.1/16"),
		mustInterface("br-0a1b2c3d4e5f", "02:42:00:00:00:02", "198.51.100.1/24"),
		mustInterface("vxlan.calico", "02:42:00:00:00:03", "198.51.100.64/32"),
		mustInterface("eth0", "00:00:5e:00:53:20", "192.0.2.20/24"),
	}

	gotIP, gotMACs := selectHostIdentity("", interfaces)
	if gotIP != hostNICIP {
		t.Fatalf("selectHostIdentity() IP = %q, want 192.0.2.20 instead of container bridge", gotIP)
	}
	if len(gotMACs) != 1 || gotMACs[0] != "00:00:5e:00:53:20" {
		t.Fatalf("selectHostIdentity() MACs = %v, want [00:00:5e:00:53:20]", gotMACs)
	}

	pinnedIP, pinnedMACs := selectHostIdentity("198.51.100.1", interfaces)
	if pinnedIP != "198.51.100.1" {
		t.Fatalf("selectHostIdentity(configured) IP = %q, want configured 198.51.100.1", pinnedIP)
	}
	if len(pinnedMACs) != 1 || pinnedMACs[0] != "02:42:00:00:00:02" {
		t.Fatalf("selectHostIdentity(configured) MACs = %v, want [02:42:00:00:00:02]", pinnedMACs)
	}

	loop := NewPushLoop(&Server{config: &ServerConfig{HostIP: "203.0.113.9"}}, nil, 0, logger.NewTestLogger())
	loop.hostInventory = func() []hostInterface { return interfaces }
	if got := loop.getSourceIP(); got != hostNICIP {
		t.Fatalf("getSourceIP() = %q, want 192.0.2.20 instead of container bridge", got)
	}
}

func TestIsHostInternalAddressMatchesGuestAddressRules(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name      string
		ifaceName string
		address   string
		want      bool
	}{
		{"docker0 name", "docker0", "192.0.2.10/24", true},
		{"docker br-hex name", "br-0a1b2c3d4e5f", "192.0.2.10/24", true},
		{"calico overlay name", "vxlan.calico", "198.51.100.64/32", true},
		{"docker default bridge CIDR", "app-bridge", "172.17.0.1/16", true},
		{"own prefix gateway /24", "ens5", "198.51.100.1/24", true},
		{"own prefix gateway /25", "ens5", "198.51.100.129/25", true},
		{"host route /32 not gateway", "eth0", "192.0.2.1/32", false},
		{"p2p /31 not gateway", "eth0", "192.0.2.1/31", false},
		{"linux bridge br0 host IP", "br0", "192.0.2.20/24", false},
		{"proxmox bridge vmbr0 host IP", "vmbr0", "192.0.2.20/24", false},
		{"regular NIC eth0", "eth0", "192.0.2.20/24", false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isHostInternalAddress(tc.ifaceName, tc.address); got != tc.want {
				t.Fatalf("isHostInternalAddress(%q, %q) = %v, want %v", tc.ifaceName, tc.address, got, tc.want)
			}
		})
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
