package agent

import (
	"net"
	"reflect"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestHostIdentityUsesOnlyUnambiguousAnnouncedInterface(t *testing.T) {
	iface := func(mac, ip string, flags net.Flags) hostInterface {
		hardware, err := net.ParseMAC(mac)
		if err != nil {
			t.Fatal(err)
		}
		return hostInterface{Interface: net.Interface{HardwareAddr: hardware, Flags: flags},
			addresses: []net.Addr{&net.IPNet{IP: net.ParseIP(ip)}}}
	}
	owner := iface("02:00:00:00:01:03", "192.0.2.37", net.FlagUp)
	other := iface("02:00:00:00:01:05", "198.51.100.41", net.FlagUp)
	tests := []struct {
		name       string
		ip         string
		interfaces []hostInterface
		want       []string
	}{
		{"owner only", "192.0.2.37", []hostInterface{other, owner}, []string{"02:00:00:00:01:03"}},
		{"stale pin", "203.0.113.9", []hostInterface{owner, other}, nil},
		{"invalid IP", "invalid", []hostInterface{owner}, nil},
		{"no interfaces", "192.0.2.37", nil, nil},
		{"duplicate owner", "192.0.2.37", []hostInterface{owner, iface("02:00:00:00:01:07", "192.0.2.37", net.FlagUp)}, nil},
		{"down", "192.0.2.37", []hostInterface{iface("02:00:00:00:01:03", "192.0.2.37", 0)}, nil},
		{"multicast MAC", "192.0.2.37", []hostInterface{iface("01:00:00:00:01:03", "192.0.2.37", net.FlagUp)}, nil},
		{"zero MAC", "192.0.2.37", []hostInterface{iface("00:00:00:00:00:00", "192.0.2.37", net.FlagUp)}, nil},
		{"loopback", "127.0.0.1", []hostInterface{iface("02:00:00:00:01:03", "127.0.0.1", net.FlagUp|net.FlagLoopback)}, nil},
		{"IPv6", "2001:db8::37", []hostInterface{iface("02:00:00:00:01:09", "2001:db8::37", net.FlagUp)}, []string{"02:00:00:00:01:09"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := selectHostInterfaceMACs(net.ParseIP(test.ip), test.interfaces); !reflect.DeepEqual(got, test.want) {
				t.Fatalf("got %v, want %v", got, test.want)
			}
		})
	}
}

// TestHelloRequestsCarryAnnouncedInterfaceMAC verifies that both the
// control-stream hello and the unary enrollment hello populate HostMacs with
// the MAC of the interface that owns the announced host IP. The interface
// inventory is injected via hostInventoryProvider so the assertion always runs,
// including on CI executors without an active Ethernet interface.
//
// The fake inventory includes interfaces that must be filtered out (loopback,
// down, multicast-MAC, zero-MAC, and one that owns a different address) alongside
// the single valid owner, so the selection logic is exercised end-to-end.
func TestHelloRequestsCarryAnnouncedInterfaceMAC(t *testing.T) {
	const wantMAC = "00:00:5e:00:53:01"

	// Resolve the source IP the loop would announce so the fake inventory can
	// claim ownership of that exact address. getSourceIP reads the OS interfaces
	// and picks the best match; using a documentation-range address would fall
	// through to the real machine IP, so we read it first.
	probe := NewPushLoop(&Server{config: &ServerConfig{}}, nil, 0, logger.NewTestLogger())
	hostIP := probe.getSourceIP()
	if hostIP == "" {
		t.Skip("no source IP available on this executor")
	}

	ownerHW, err := net.ParseMAC(wantMAC)
	if err != nil {
		t.Fatal(err)
	}
	ownerAddr := &net.IPNet{IP: net.ParseIP(hostIP), Mask: net.CIDRMask(24, 32)}
	otherAddr := &net.IPNet{IP: net.ParseIP("198.51.100.7"), Mask: net.CIDRMask(24, 32)}

	saved := hostInventoryProvider
	hostInventoryProvider = func() []hostInterface {
		return []hostInterface{
			// loopback — must be filtered
			{Interface: net.Interface{Name: "lo", Flags: net.FlagUp | net.FlagLoopback,
				HardwareAddr: net.HardwareAddr{0x00, 0x00, 0x00, 0x00, 0x00, 0x00}},
				addresses: []net.Addr{ownerAddr}},
			// down — must be filtered
			{Interface: net.Interface{Name: "eth1", Flags: 0, HardwareAddr: ownerHW},
				addresses: []net.Addr{ownerAddr}},
			// multicast MAC (LSB of first octet set) — must be filtered
			{Interface: net.Interface{Name: "eth2", Flags: net.FlagUp,
				HardwareAddr: net.HardwareAddr{0x01, 0x00, 0x5e, 0x00, 0x53, 0x02}},
				addresses: []net.Addr{ownerAddr}},
			// zero MAC — must be filtered
			{Interface: net.Interface{Name: "eth3", Flags: net.FlagUp,
				HardwareAddr: net.HardwareAddr{0x00, 0x00, 0x00, 0x00, 0x00, 0x00}},
				addresses: []net.Addr{ownerAddr}},
			// up with valid MAC but a different address — not selected
			{Interface: net.Interface{Name: "eth4", Flags: net.FlagUp,
				HardwareAddr: net.HardwareAddr{0x00, 0x00, 0x5e, 0x00, 0x53, 0x03}},
				addresses: []net.Addr{otherAddr}},
			// the valid owner: up, unicast MAC, owns hostIP
			{Interface: net.Interface{Name: "eth0", Flags: net.FlagUp, HardwareAddr: ownerHW},
				addresses: []net.Addr{ownerAddr}},
		}
	}
	defer func() { hostInventoryProvider = saved }()

	loop := NewPushLoop(&Server{config: &ServerConfig{HostIP: hostIP}}, nil, 0, logger.NewTestLogger())

	// Control-stream hello
	stream := &fakeControlStreamClient{}
	if err := loop.sendControlHello(newControlStreamSender(stream)); err != nil {
		t.Fatal(err)
	}
	controlHello := stream.sent[0].GetHello()
	if controlHello.HostIp != hostIP {
		t.Fatalf("control hello HostIp = %q, want %q", controlHello.HostIp, hostIP)
	}
	if !reflect.DeepEqual(controlHello.HostMacs, []string{wantMAC}) {
		t.Fatalf("control hello HostMacs = %v, want %v", controlHello.HostMacs, []string{wantMAC})
	}

	// Enrollment hello
	enrollHello := loop.buildEnrollmentHelloRequest()
	if enrollHello.HostIp != hostIP {
		t.Fatalf("enrollment hello HostIp = %q, want %q", enrollHello.HostIp, hostIP)
	}
	if !reflect.DeepEqual(enrollHello.HostMacs, []string{wantMAC}) {
		t.Fatalf("enrollment hello HostMacs = %v, want %v", enrollHello.HostMacs, []string{wantMAC})
	}
}
