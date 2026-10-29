package agent

import (
	"net"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/hostinventory"
	"github.com/carverauto/serviceradar/proto"
)

const maxGatewayPrefixLen = 30

// hostInterface is one entry of the shared host interface inventory.
type hostInterface = hostinventory.Interface

func defaultHostInventory() []hostInterface {
	return hostinventory.Collect()
}

// hostIdentityReport is what both hello transports announce about the host:
// the announced IP, the MAC of the interface owning it (host_macs, for cores
// that predate the inventory) and the full classified inventory, all from one
// snapshot.
type hostIdentityReport struct {
	ip         string
	macs       []string
	interfaces []*proto.HostInterface
}

// hostIdentity selects the announced IP and its MACs, and converts the
// inventory, from one inventory snapshot. A nil inventory uses the same
// operating-system interfaces as getSourceIP.
func hostIdentity(configured string, inventory func() []hostInterface) hostIdentityReport {
	if inventory == nil {
		inventory = defaultHostInventory
	}
	interfaces := inventory()
	ip, macs := selectHostIdentity(configured, interfaces)

	return hostIdentityReport{ip: ip, macs: macs, interfaces: hostInterfacesProto(interfaces)}
}

// hostInterfacesProto reports every interface but loopback with the
// platform's classification. Core, not the agent, decides which of these MACs
// identify the host, so nothing is left out for being a bridge, a guest
// device or a container interface: it is reported as one.
func hostInterfacesProto(interfaces []hostInterface) []*proto.HostInterface {
	hostInterfaceKinds := map[hostinventory.Kind]proto.HostInterfaceKind{
		hostinventory.KindPhysical: proto.HostInterfaceKind_HOST_INTERFACE_KIND_PHYSICAL,
		hostinventory.KindBond:     proto.HostInterfaceKind_HOST_INTERFACE_KIND_BOND,
		hostinventory.KindBridge:   proto.HostInterfaceKind_HOST_INTERFACE_KIND_BRIDGE,
		hostinventory.KindVLAN:     proto.HostInterfaceKind_HOST_INTERFACE_KIND_VLAN,
		hostinventory.KindVirtual:  proto.HostInterfaceKind_HOST_INTERFACE_KIND_VIRTUAL,
		hostinventory.KindTunnel:   proto.HostInterfaceKind_HOST_INTERFACE_KIND_TUNNEL,
		hostinventory.KindLoopback: proto.HostInterfaceKind_HOST_INTERFACE_KIND_LOOPBACK,
	}

	macProvenances := map[hostinventory.MACProvenance]proto.MacProvenance{
		hostinventory.ProvenancePermanent: proto.MacProvenance_MAC_PROVENANCE_PERMANENT,
		hostinventory.ProvenanceRandom:    proto.MacProvenance_MAC_PROVENANCE_RANDOM,
		hostinventory.ProvenanceInherited: proto.MacProvenance_MAC_PROVENANCE_INHERITED,
		hostinventory.ProvenanceAssigned:  proto.MacProvenance_MAC_PROVENANCE_ASSIGNED,
	}

	out := make([]*proto.HostInterface, 0, len(interfaces))
	for _, iface := range interfaces {
		if iface.Kind == hostinventory.KindLoopback || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		entry := &proto.HostInterface{
			Name:          iface.Name,
			Ips:           iface.IPs(),
			OperState:     iface.OperState,
			Kind:          hostInterfaceKinds[iface.Kind],
			MacProvenance: macProvenances[iface.MACProvenance],
			Master:        iface.Master,
		}
		if len(iface.HardwareAddr) > 0 {
			entry.Mac = iface.HardwareAddr.String()
		}
		if len(iface.PermanentMAC) > 0 {
			entry.PermanentMac = iface.PermanentMAC.String()
		}
		out = append(out, entry)
	}

	return out
}

func selectHostIdentity(configured string, interfaces []hostInterface) (string, []string) {
	hostIP := selectSourceIPFromInterfaces(configured, interfaces)
	return hostIP, selectHostInterfaceMACs(net.ParseIP(hostIP), interfaces)
}

func selectSourceIPFromInterfaces(configured string, interfaces []hostInterface) string {
	configured = strings.TrimSpace(configured)
	if configured != "" && localIPsContain(allSourceIPsFromInterfaces(interfaces), configured) {
		return configured
	}
	if detected := preferLocalSourceIP(candidateSourceIPsFromInterfaces(interfaces)); detected != "" {
		return detected
	}
	return configured
}

func allSourceIPsFromInterfaces(interfaces []hostInterface) []net.IP {
	var ips []net.IP
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		for _, address := range iface.Addrs {
			ip, _ := hostAddrString(address)
			if ip != nil && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() {
				ips = append(ips, ip)
			}
		}
	}
	return ips
}

func candidateSourceIPsFromInterfaces(interfaces []hostInterface) []net.IP {
	var ips []net.IP
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		for _, address := range iface.Addrs {
			ip, rawAddress := hostAddrString(address)
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}
			if isHostInternalAddress(iface.Name, rawAddress) {
				continue
			}
			ips = append(ips, ip)
		}
	}
	return ips
}

func hostAddrString(addr net.Addr) (net.IP, string) {
	switch value := addr.(type) {
	case *net.IPNet:
		if value == nil || value.IP == nil {
			return nil, ""
		}
		if ones, bits := value.Mask.Size(); bits == 32 && ones > 0 {
			return value.IP, value.String()
		}
		return value.IP, value.IP.String()
	case *net.IPAddr:
		if value == nil || value.IP == nil {
			return nil, ""
		}
		return value.IP, value.IP.String()
	default:
		return nil, ""
	}
}

// isHostInternalAddress mirrors ServiceRadar.Inventory.Identity.GuestAddress so
// host-internal container bridges and CNI overlays never win fallback IP selection.
func isHostInternalAddress(ifaceName, rawAddress string) bool {
	return hostinventory.IsHostInternalName(ifaceName) ||
		isDockerDefaultBridgeAddress(rawAddress) ||
		isOwnPrefixGatewayAddress(rawAddress)
}

func isDockerDefaultBridgeAddress(rawAddress string) bool {
	ipText := strings.TrimSpace(rawAddress)
	if idx := strings.IndexByte(ipText, '/'); idx >= 0 {
		ipText = ipText[:idx]
	}
	octets, ok := parseIPv4Octets(ipText)
	return ok && octets[0] == 172 && octets[1] == 17
}

func isDockerDefaultBridgeIP(ip net.IP) bool {
	ip4 := ip.To4()
	return ip4 != nil && ip4[0] == 172 && ip4[1] == 17
}

func isOwnPrefixGatewayAddress(rawAddress string) bool {
	ipText, prefixText, ok := strings.Cut(strings.TrimSpace(rawAddress), "/")
	if !ok {
		return false
	}
	octets, ok := parseIPv4Octets(ipText)
	if !ok {
		return false
	}
	prefixLen, err := strconv.Atoi(strings.TrimSpace(prefixText))
	if err != nil || prefixLen < 1 || prefixLen > maxGatewayPrefixLen {
		return false
	}
	hostBits := (uint32(1) << (32 - prefixLen)) - 1
	addr := uint32(octets[0])<<24 | uint32(octets[1])<<16 | uint32(octets[2])<<8 | uint32(octets[3])
	return (addr & hostBits) == 1
}

func parseIPv4Octets(raw string) ([4]byte, bool) {
	var octets [4]byte
	parts := strings.Split(strings.TrimSpace(raw), ".")
	if len(parts) != 4 {
		return octets, false
	}
	for i, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return octets, false
		}
		n, err := strconv.Atoi(part)
		if err != nil || n < 0 || n > 255 {
			return octets, false
		}
		octets[i] = byte(n)
	}
	return octets, true
}

// host_macs carries only the MAC of the interface owning the announced IP, as
// cores that predate host_interfaces expect: they register every host_macs value
// as identity and cannot tell a bridge or guest device from a NIC.
func selectHostInterfaceMACs(hostIP net.IP, interfaces []hostInterface) []string {
	if hostIP == nil || hostIP.IsLoopback() || hostIP.IsUnspecified() || hostIP.IsMulticast() {
		return nil
	}
	var selected string
	for _, iface := range interfaces {
		mac := iface.HardwareAddr
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 ||
			len(mac) != 6 || mac[0]&1 != 0 || mac.String() == "00:00:00:00:00:00" {
			continue
		}
		for _, address := range iface.Addrs {
			var ip net.IP
			switch value := address.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if !hostIP.Equal(ip) {
				continue
			}
			if selected != "" && selected != mac.String() {
				return nil // Ambiguous ownership is not identity evidence.
			}
			selected = mac.String()
		}
	}
	if selected == "" {
		return nil
	}
	return []string{selected}
}
