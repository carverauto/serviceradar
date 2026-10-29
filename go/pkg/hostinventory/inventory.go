// Package hostinventory enumerates and classifies the local host's network
// interfaces. It is the one place the agent decides what kind of interface it
// is looking at (a physical NIC, a bond, a bridge, a VLAN, a tunnel, a virtual
// device such as a veth or tap) and how each interface's MAC was assigned.
//
// The package classifies; it never decides identity. The agent reports every
// interface with its classification, and core decides which MACs are strong
// identity (only the permanent, globally administered MACs of physical NICs and
// bond members). Keeping the classification here, and the decision in core,
// means a classification fix never needs a matching edit in the identity rules.
package hostinventory

import (
	"net"
	"sort"
	"strings"
)

// Kind is what an interface is, as the operating system describes it.
type Kind string

// Interface kinds. KindUnspecified means the platform cannot tell, which is
// every interface but loopback outside Linux.
const (
	KindUnspecified Kind = ""
	KindPhysical    Kind = "physical"
	KindBond        Kind = "bond"
	KindBridge      Kind = "bridge"
	KindVLAN        Kind = "vlan"
	KindVirtual     Kind = "virtual"
	KindTunnel      Kind = "tunnel"
	KindLoopback    Kind = "loopback"
)

// MACProvenance says how an interface's current MAC was assigned (Linux
// addr_assign_type).
type MACProvenance string

// MAC provenances. ProvenanceUnknown means the platform does not say.
const (
	ProvenanceUnknown   MACProvenance = ""
	ProvenancePermanent MACProvenance = "permanent" // burned in (NET_ADDR_PERM)
	ProvenanceRandom    MACProvenance = "random"    // generated (NET_ADDR_RANDOM)
	ProvenanceInherited MACProvenance = "inherited" // taken from another device (NET_ADDR_STOLEN)
	ProvenanceAssigned  MACProvenance = "assigned"  // set by software (NET_ADDR_SET)
)

// Interface is one local interface with its addresses and classification.
type Interface struct {
	net.Interface
	Addrs         []net.Addr
	Kind          Kind
	MACProvenance MACProvenance
	// PermanentMAC is the NIC's own hardware address when the platform reports
	// it: the current MAC when it is permanent, or a bond member's perm_hwaddr,
	// which bonding hides behind the bond's MAC.
	PermanentMAC net.HardwareAddr
	OperState    string
	// Master is the bridge or bond this interface is enslaved to, if any.
	Master string
}

// Classification is what the platform says about one interface beyond what
// net.Interface carries.
type Classification struct {
	Kind          Kind
	MACProvenance MACProvenance
	PermanentMAC  net.HardwareAddr
	OperState     string
	Master        string
}

// Collect enumerates the host's interfaces and classifies each one. An
// interface whose addresses cannot be read is still reported, without them.
func Collect() []Interface {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}

	out := make([]Interface, 0, len(interfaces))
	for _, iface := range interfaces {
		addresses, err := iface.Addrs()
		if err != nil {
			addresses = nil
		}
		out = append(out, Classify(iface, addresses, platformClassify(iface)))
	}

	return out
}

// Classify combines an interface, its addresses and the platform's
// classification into one inventory entry.
func Classify(iface net.Interface, addresses []net.Addr, class Classification) Interface {
	return Interface{
		Interface:     iface,
		Addrs:         addresses,
		Kind:          class.Kind,
		MACProvenance: class.MACProvenance,
		PermanentMAC:  class.PermanentMAC,
		OperState:     class.OperState,
		Master:        class.Master,
	}
}

// IPs returns every address on the interface, IPv4 and IPv6, without its
// prefix length, sorted and de-duplicated.
func (i Interface) IPs() []string {
	seen := make(map[string]bool, len(i.Addrs))
	var out []string
	for _, address := range i.Addrs {
		var ip net.IP
		switch value := address.(type) {
		case *net.IPNet:
			if value != nil {
				ip = value.IP
			}
		case *net.IPAddr:
			if value != nil {
				ip = value.IP
			}
		}
		if ip == nil {
			continue
		}
		text := ip.String()
		if !seen[text] {
			seen[text] = true
			out = append(out, text)
		}
	}
	sort.Strings(out)

	return out
}

// IsHostInternalName reports whether an interface name is one of the host's
// internal container, overlay or guest interfaces. It works on every platform,
// so it is how host IP selection skips them where sysfs is not available.
func IsHostInternalName(name string) bool {
	normalized := strings.ToLower(strings.TrimSpace(name))
	if normalized == "" {
		return false
	}
	// These prefixes name container bridges, CNI overlays, guest
	// devices and other interfaces internal to the host. It mirrors
	// ServiceRadar.Inventory.Identity.GuestAddress on the core side.
	hostInternalNamePrefixes := []string{
		"docker",
		"br-",
		"cni",
		"flannel",
		"veth",
		"virbr",
		"cali",
		"vxlan",
		"tunl",
		"cilium",
		"kube-",
		"weave",
		"podman",
		"lxcbr",
		"lxdbr",
	}

	for _, prefix := range hostInternalNamePrefixes {
		if strings.HasPrefix(normalized, prefix) {
			return true
		}
	}

	return false
}

// flagClassification is what net.Interface flags alone say: loopback, and an
// operational state of up or down. Platforms without sysfs use it.
func flagClassification(iface net.Interface) Classification {
	class := Classification{OperState: "down"}
	if iface.Flags&net.FlagUp != 0 {
		class.OperState = "up"
	}
	if iface.Flags&net.FlagLoopback != 0 {
		class.Kind = KindLoopback
	}

	return class
}
