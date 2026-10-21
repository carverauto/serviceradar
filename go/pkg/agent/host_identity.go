package agent

import (
	"net"
	"strconv"
	"strings"
)

var hostInternalInterfacePrefixes = []string{
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

const maxGatewayPrefixLen = 30

type hostInterface struct {
	net.Interface
	addresses []net.Addr
}

func defaultHostInventory() []hostInterface {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	local := make([]hostInterface, 0, len(interfaces))
	for _, iface := range interfaces {
		if addresses, err := iface.Addrs(); err == nil {
			local = append(local, hostInterface{Interface: iface, addresses: addresses})
		}
	}
	return local
}

// hostIdentity selects the announced IP and its MACs from one inventory snapshot.
// A nil inventory uses the same operating-system interfaces as getSourceIP.
func hostIdentity(configured string, inventory func() []hostInterface) (string, []string) {
	if inventory == nil {
		inventory = defaultHostInventory
	}
	return selectHostIdentity(configured, inventory())
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
		for _, address := range iface.addresses {
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
		for _, address := range iface.addresses {
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
	return isHostInternalInterfaceName(ifaceName) ||
		isDockerDefaultBridgeAddress(rawAddress) ||
		isOwnPrefixGatewayAddress(rawAddress)
}

func isHostInternalInterfaceName(name string) bool {
	normalized := strings.ToLower(strings.TrimSpace(name))
	if normalized == "" {
		return false
	}
	for _, prefix := range hostInternalInterfacePrefixes {
		if strings.HasPrefix(normalized, prefix) {
			return true
		}
	}
	return false
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

// Only report the interface that owns the announced IP. Enumerating every MAC
// would also claim bridges, guest veths and unrelated network namespaces.
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
		for _, address := range iface.addresses {
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
