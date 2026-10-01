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

func TestControlHelloCarriesAnnouncedInterfaceMAC(t *testing.T) {
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || len(iface.HardwareAddr) != 6 || iface.HardwareAddr[0]&1 != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			t.Fatal(err)
		}
		for _, address := range addresses {
			network, ok := address.(*net.IPNet)
			if !ok || network.IP.To4() == nil || !network.IP.IsGlobalUnicast() {
				continue
			}
			loop := NewPushLoop(&Server{config: &ServerConfig{HostIP: network.IP.String()}}, nil, 0, logger.NewTestLogger())
			stream := &fakeControlStreamClient{}
			if err := loop.sendControlHello(newControlStreamSender(stream)); err != nil {
				t.Fatal(err)
			}
			hello := stream.sent[0].GetHello()
			if hello.HostIp != network.IP.String() || !reflect.DeepEqual(hello.HostMacs, []string{iface.HardwareAddr.String()}) {
				t.Fatal("control hello omitted or misattributed the announced interface identity")
			}
			return
		}
	}
	t.Skip("requires an active Ethernet interface with a local IPv4 address")
}
