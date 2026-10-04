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

// Both hello transports must announce an IP and its owner's MAC from the
// injected inventory, regardless of the executor's network configuration.
func TestHelloRequestsCarryAnnouncedInterfaceMAC(t *testing.T) {
	iface := func(name, mac, ip string, flags net.Flags) hostInterface {
		hardware, err := net.ParseMAC(mac)
		if err != nil {
			t.Fatal(err)
		}
		return hostInterface{Interface: net.Interface{Name: name, HardwareAddr: hardware, Flags: flags},
			addresses: []net.Addr{&net.IPNet{IP: net.ParseIP(ip)}}}
	}
	interfaces := []hostInterface{
		iface("lo", "00:00:00:00:00:00", "127.0.0.1", net.FlagUp|net.FlagLoopback),
		iface("down", "00:00:5e:00:53:01", "203.0.113.9", 0),
		iface("multicast", "01:00:5e:00:53:02", "192.0.2.37", net.FlagUp),
		iface("zero", "00:00:00:00:00:00", "192.0.2.37", net.FlagUp),
		iface("owner", "00:00:5e:00:53:01", "192.0.2.37", net.FlagUp),
		iface("other", "00:00:5e:00:53:03", "198.51.100.41", net.FlagUp),
	}
	tests := []struct {
		name       string
		configured string
		wantIP     string
		wantMACs   []string
		interfaces []hostInterface
	}{
		{"pinned local IP", "198.51.100.41", "198.51.100.41", []string{"00:00:5e:00:53:03"}, interfaces},
		{"stale pin", "203.0.113.9", "192.0.2.37", []string{"00:00:5e:00:53:01"}, interfaces},
		{"unconfigured", "", "192.0.2.37", []string{"00:00:5e:00:53:01"}, interfaces},
		{"no interfaces retains pin without claiming MAC", "203.0.113.9", "203.0.113.9", nil, nil},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			loop := NewPushLoop(&Server{config: &ServerConfig{HostIP: test.configured}}, nil, 0, logger.NewTestLogger())
			calls := 0
			loop.hostInventory = func() []hostInterface {
				calls++
				return test.interfaces
			}

			stream := &fakeControlStreamClient{}
			if err := loop.sendControlHello(newControlStreamSender(stream)); err != nil {
				t.Fatal(err)
			}
			if len(stream.sent) == 0 || stream.sent[0].GetHello() == nil {
				t.Fatal("control stream did not send an initial hello")
			}
			controlHello := stream.sent[0].GetHello()
			if controlHello.HostIp != test.wantIP || !reflect.DeepEqual(controlHello.HostMacs, test.wantMACs) {
				t.Fatalf("control hello identity = %q/%v, want %q/%v", controlHello.HostIp, controlHello.HostMacs, test.wantIP, test.wantMACs)
			}
			if calls != 1 {
				t.Fatalf("control hello read %d inventory snapshots, want 1", calls)
			}

			enrollHello := loop.buildEnrollmentHelloRequest()
			if enrollHello.HostIp != test.wantIP || !reflect.DeepEqual(enrollHello.HostMacs, test.wantMACs) {
				t.Fatalf("enrollment hello identity = %q/%v, want %q/%v", enrollHello.HostIp, enrollHello.HostMacs, test.wantIP, test.wantMACs)
			}
			if calls != 2 {
				t.Fatalf("both hellos read %d inventory snapshots, want 2", calls)
			}
		})
	}
}
