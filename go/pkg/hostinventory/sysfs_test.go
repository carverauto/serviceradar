package hostinventory

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

// fakeNetDev writes one interface's sysfs directory: files maps a relative path
// to its contents, and dirs lists relative directories (bridge/, device/, ...).
func fakeNetDev(t *testing.T, root, name string, files map[string]string, dirs ...string) {
	t.Helper()
	base := filepath.Join(root, name)
	for _, dir := range append([]string{""}, dirs...) {
		if err := os.MkdirAll(filepath.Join(base, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for path, contents := range files {
		full := filepath.Join(base, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(contents+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func mustMAC(t *testing.T, text string) net.HardwareAddr {
	t.Helper()
	mac, err := net.ParseMAC(text)
	if err != nil {
		t.Fatal(err)
	}
	return mac
}

// The classification core relies on to tell a NIC's own MAC from one a bridge,
// a bond, a guest device or the kernel made up. Every value is invented.
func TestClassifySysfs(t *testing.T) {
	root := t.TempDir()
	fakeNetDev(t, root, "eno1", map[string]string{"addr_assign_type": "0", "operstate": "up", "type": "1"}, "device")
	fakeNetDev(t, root, "eno2", map[string]string{
		"addr_assign_type":          "3",
		"operstate":                 "up",
		"type":                      "1",
		"bonding_slave/perm_hwaddr": "00:00:5e:00:53:12",
	}, "device")
	fakeNetDev(t, root, "bond0", map[string]string{"addr_assign_type": "3", "operstate": "up", "type": "1"}, "bonding")
	fakeNetDev(t, root, "vmbr0", map[string]string{"addr_assign_type": "3", "operstate": "up", "type": "1"}, "bridge")
	fakeNetDev(t, root, "eno1.20", map[string]string{"addr_assign_type": "2", "uevent": "DEVTYPE=vlan\nINTERFACE=eno1.20", "type": "1"})
	fakeNetDev(t, root, "veth1a2b", map[string]string{"addr_assign_type": "1", "operstate": "up", "type": "1"})
	fakeNetDev(t, root, "tap100i0", map[string]string{"addr_assign_type": "1", "tun_flags": "0x1002", "type": "1"})
	fakeNetDev(t, root, "tun0", map[string]string{"tun_flags": "0x1001", "type": "65534"})
	fakeNetDev(t, root, "wg0", map[string]string{"uevent": "DEVTYPE=wireguard", "type": "65534"})
	fakeNetDev(t, root, "eno1v0", map[string]string{"addr_assign_type": "0", "type": "1"}, "device", "device/physfn")
	fakeNetDev(t, root, "wlp2s0", map[string]string{"addr_assign_type": "3", "uevent": "DEVTYPE=wlan", "type": "1"}, "device")
	if err := os.Symlink("../vmbr0", filepath.Join(root, "eno1", "master")); err != nil {
		t.Fatal(err)
	}

	nicMAC := mustMAC(t, "00:00:5e:00:53:11")
	bondMAC := mustMAC(t, "00:00:5e:00:53:13")
	tests := []struct {
		name      string
		iface     net.Interface
		kind      Kind
		prov      MACProvenance
		permanent net.HardwareAddr
		master    string
		operState string
	}{
		{"physical NIC under a bridge", net.Interface{Name: "eno1", HardwareAddr: nicMAC}, KindPhysical, ProvenancePermanent, nicMAC, "vmbr0", "up"},
		{"bond member keeps its perm_hwaddr", net.Interface{Name: "eno2", HardwareAddr: bondMAC}, KindPhysical, ProvenanceAssigned, mustMAC(t, "00:00:5e:00:53:12"), "", "up"},
		{"bond", net.Interface{Name: "bond0", HardwareAddr: bondMAC}, KindBond, ProvenanceAssigned, nil, "", "up"},
		{"bridge inheriting a port MAC", net.Interface{Name: "vmbr0", HardwareAddr: nicMAC}, KindBridge, ProvenanceAssigned, nil, "", "up"},
		{"vlan", net.Interface{Name: "eno1.20", HardwareAddr: nicMAC}, KindVLAN, ProvenanceInherited, nil, "", "down"},
		{"veth", net.Interface{Name: "veth1a2b", HardwareAddr: mustMAC(t, "02:00:5e:00:53:21")}, KindVirtual, ProvenanceRandom, nil, "", "up"},
		{"tap", net.Interface{Name: "tap100i0", HardwareAddr: mustMAC(t, "02:00:5e:00:53:22")}, KindVirtual, ProvenanceRandom, nil, "", "down"},
		{"tun", net.Interface{Name: "tun0"}, KindTunnel, ProvenanceUnknown, nil, "", "down"},
		{"wireguard", net.Interface{Name: "wg0", Flags: net.FlagUp}, KindTunnel, ProvenanceUnknown, nil, "", "up"},
		{"SR-IOV virtual function", net.Interface{Name: "eno1v0", HardwareAddr: mustMAC(t, "00:00:5e:00:53:23")}, KindVirtual, ProvenancePermanent, mustMAC(t, "00:00:5e:00:53:23"), "", "down"},
		{"randomized Wi-Fi", net.Interface{Name: "wlp2s0", HardwareAddr: mustMAC(t, "02:00:5e:00:53:24")}, KindPhysical, ProvenanceAssigned, nil, "", "down"},
		{"loopback", net.Interface{Name: "lo", Flags: net.FlagUp | net.FlagLoopback}, KindLoopback, ProvenanceUnknown, nil, "", "up"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := ClassifySysfs(root, test.iface)
			if got.Kind != test.kind || got.MACProvenance != test.prov || got.Master != test.master ||
				got.OperState != test.operState || got.PermanentMAC.String() != test.permanent.String() {
				t.Fatalf("ClassifySysfs(%s) = %+v, want kind %q provenance %q permanent %q master %q operstate %q",
					test.iface.Name, got, test.kind, test.prov, test.permanent, test.master, test.operState)
			}
		})
	}
}

func TestInterfaceIPsReportsEveryFamilyOnce(t *testing.T) {
	_, v4, _ := net.ParseCIDR("192.0.2.10/24")
	v4.IP = net.ParseIP("192.0.2.10")
	iface := Interface{Addrs: []net.Addr{
		v4,
		&net.IPAddr{IP: net.ParseIP("2001:db8::10")},
		&net.IPNet{IP: net.ParseIP("192.0.2.10"), Mask: net.CIDRMask(32, 32)},
	}}
	got := iface.IPs()
	if len(got) != 2 || got[0] != "192.0.2.10" || got[1] != "2001:db8::10" {
		t.Fatalf("IPs() = %v, want [192.0.2.10 2001:db8::10]", got)
	}
}

func TestIsHostInternal(t *testing.T) {
	tests := []struct {
		name     string
		iface    Interface
		internal bool
	}{
		{"physical NIC", Interface{Interface: net.Interface{Name: "eno1"}, Kind: KindPhysical}, false},
		{"bond", Interface{Interface: net.Interface{Name: "bond0"}, Kind: KindBond}, false},
		{"VLAN", Interface{Interface: net.Interface{Name: "eno1.20"}, Kind: KindVLAN}, false},
		{"Proxmox host bridge", Interface{Interface: net.Interface{Name: "vmbr0"}, Kind: KindBridge}, false},
		{"Linux host bridge", Interface{Interface: net.Interface{Name: "br0"}, Kind: KindBridge}, false},
		{"non-sysfs physical NIC", Interface{Interface: net.Interface{Name: "en0"}, Kind: KindUnspecified}, false},
		{"loopback by kind", Interface{Interface: net.Interface{Name: "lo"}, Kind: KindLoopback}, true},
		{"loopback by name", Interface{Interface: net.Interface{Name: "lo0"}, Kind: KindUnspecified}, true},
		{"virtual veth", Interface{Interface: net.Interface{Name: "veth1a2b"}, Kind: KindVirtual}, true},
		{"virtual custom name", Interface{Interface: net.Interface{Name: "guest0"}, Kind: KindVirtual}, false},
		{"container uplink", Interface{Interface: net.Interface{Name: "eth0"}, Kind: KindVirtual}, false},
		{"SR-IOV uplink", Interface{Interface: net.Interface{Name: "eno1v0"}, Kind: KindVirtual}, false},
		{"tunnel wireguard", Interface{Interface: net.Interface{Name: "wg0"}, Kind: KindTunnel}, true},
		{"docker bridge", Interface{Interface: net.Interface{Name: "docker0"}, Kind: KindBridge}, true},
		{"docker custom bridge", Interface{Interface: net.Interface{Name: "br-0123456789ab"}, Kind: KindBridge}, true},
		{"libvirt bridge", Interface{Interface: net.Interface{Name: "virbr0"}, Kind: KindBridge}, true},
		{"cni bridge", Interface{Interface: net.Interface{Name: "cni0"}, Kind: KindBridge}, true},
		{"KVM vnet fallback", Interface{Interface: net.Interface{Name: "vnet0"}, Kind: KindUnspecified}, true},
		{"tun fallback", Interface{Interface: net.Interface{Name: "tun0"}, Kind: KindUnspecified}, true},
		{"tap fallback", Interface{Interface: net.Interface{Name: "tap0"}, Kind: KindUnspecified}, true},
		{"macOS bridge fallback", Interface{Interface: net.Interface{Name: "bridge0"}, Kind: KindUnspecified}, true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := test.iface.IsHostInternal(); got != test.internal {
				t.Fatalf("Interface(%s, kind=%q).IsHostInternal() = %v, want %v",
					test.iface.Name, test.iface.Kind, got, test.internal)
			}
		})
	}
}

func TestInterfaceIsTrafficInternalKeepsRoutedTunnels(t *testing.T) {
	tests := []struct {
		name     string
		iface    Interface
		internal bool
	}{
		{"tunnel wireguard", Interface{Interface: net.Interface{Name: "wg0"}, Kind: KindTunnel}, false},
		{"tunnel gre", Interface{Interface: net.Interface{Name: "gre1"}, Kind: KindTunnel}, false},
		{"physical NIC", Interface{Interface: net.Interface{Name: "eno1"}, Kind: KindPhysical}, false},
		{"Proxmox host bridge", Interface{Interface: net.Interface{Name: "vmbr0"}, Kind: KindBridge}, false},
		{"loopback by kind", Interface{Interface: net.Interface{Name: "lo"}, Kind: KindLoopback}, true},
		{"loopback by flag", Interface{Interface: net.Interface{Name: "lo0", Flags: net.FlagLoopback}}, true},
		{"tun fallback", Interface{Interface: net.Interface{Name: "tun0"}, Kind: KindUnspecified}, true},
		{"virtual veth", Interface{Interface: net.Interface{Name: "veth1a2b"}, Kind: KindVirtual}, true},
		{"cni bridge", Interface{Interface: net.Interface{Name: "cni0"}, Kind: KindBridge}, true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := test.iface.IsTrafficInternal(); got != test.internal {
				t.Fatalf("Interface(%s, kind=%q).IsTrafficInternal() = %v, want %v",
					test.iface.Name, test.iface.Kind, got, test.internal)
			}
		})
	}

	// A routed tunnel still never becomes the host's announced address.
	tunnel := Interface{Interface: net.Interface{Name: "wg0"}, Kind: KindTunnel}
	if !tunnel.IsHostInternal() {
		t.Fatal("tunnel interface must stay host-internal for host IP selection")
	}
}
