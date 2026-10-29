package hostinventory

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ARPHRD types (include/uapi/linux/if_arp.h) of interfaces that carry no
// Ethernet link of their own: IP-in-IP, IPv6 tunnels, SIT, GRE, IPv6 GRE, and
// ARPHRD_NONE (tun, WireGuard).
func isTunnelLinkType(linkType string) bool {
	switch linkType {
	case "768", "769", "776", "778", "823", "65534":
		return true
	default:
		return false
	}
}

func isTunnelDevType(devType string) bool {
	switch devType {
	case "wireguard", "ipip", "gre", "sit", "ip6tnl", "geneve":
		return true
	default:
		return false
	}
}

// ClassifySysfs classifies one interface from a Linux sysfs net tree rooted at
// root (normally /sys/class/net). Every file is optional: an interface the tree
// does not describe gets the flag-only classification, and a missing file
// leaves its field unknown. Reading sysfs needs no privilege.
func ClassifySysfs(root string, iface net.Interface) Classification {
	dir := filepath.Join(root, iface.Name)
	if !exists(dir) {
		return flagClassification(iface)
	}

	class := Classification{
		Kind:          sysfsKind(dir, iface),
		MACProvenance: sysfsProvenance(readTrimmed(filepath.Join(dir, "addr_assign_type"))),
		OperState:     readTrimmed(filepath.Join(dir, "operstate")),
	}
	if class.OperState == "" {
		class.OperState = flagClassification(iface).OperState
	}
	if master, err := os.Readlink(filepath.Join(dir, "master")); err == nil {
		class.Master = filepath.Base(master)
	}

	// Bonding rewrites a member's MAC to the bond's and keeps the member's own
	// in perm_hwaddr. Otherwise the current MAC is the NIC's own only when the
	// kernel says it is permanent.
	if perm, err := net.ParseMAC(readTrimmed(filepath.Join(dir, "bonding_slave", "perm_hwaddr"))); err == nil {
		class.PermanentMAC = perm
	} else if class.MACProvenance == ProvenancePermanent && len(iface.HardwareAddr) > 0 {
		class.PermanentMAC = iface.HardwareAddr
	}

	return class
}

func sysfsKind(dir string, iface net.Interface) Kind {
	devType := ueventDevType(filepath.Join(dir, "uevent"))

	switch {
	case iface.Flags&net.FlagLoopback != 0 || readTrimmed(filepath.Join(dir, "type")) == "772":
		return KindLoopback
	case exists(filepath.Join(dir, "bridge")):
		return KindBridge
	case exists(filepath.Join(dir, "bonding")):
		return KindBond
	case devType == "vlan":
		return KindVLAN
	case exists(filepath.Join(dir, "tun_flags")):
		// One driver serves both: a tap is a virtual Ethernet device (a guest's
		// NIC on the host side), a tun an L3 tunnel.
		if tunFlagTap(readTrimmed(filepath.Join(dir, "tun_flags"))) {
			return KindVirtual
		}
		return KindTunnel
	case isTunnelDevType(devType) || isTunnelLinkType(readTrimmed(filepath.Join(dir, "type"))):
		return KindTunnel
	// A physical NIC has a bus device behind it. An SR-IOV virtual function
	// does too, but its physfn link names the NIC it belongs to.
	case exists(filepath.Join(dir, "device")) && !exists(filepath.Join(dir, "device", "physfn")):
		return KindPhysical
	default:
		// veth, tap, dummy, macvlan, ipvlan and the like.
		return KindVirtual
	}
}

// IFF_TAP (include/uapi/linux/if_tun.h).
const iffTap = 0x0002

func tunFlagTap(flags string) bool {
	value, err := strconv.ParseUint(strings.TrimPrefix(flags, "0x"), 16, 32)
	return err == nil && value&iffTap != 0
}

func sysfsProvenance(addrAssignType string) MACProvenance {
	switch addrAssignType {
	case "0":
		return ProvenancePermanent
	case "1":
		return ProvenanceRandom
	case "2":
		return ProvenanceInherited
	case "3":
		return ProvenanceAssigned
	default:
		return ProvenanceUnknown
	}
}

func ueventDevType(path string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer func() { _ = file.Close() }()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		if value, ok := strings.CutPrefix(scanner.Text(), "DEVTYPE="); ok {
			return strings.TrimSpace(value)
		}
	}

	return ""
}

func readTrimmed(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}

	return strings.TrimSpace(string(data))
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
