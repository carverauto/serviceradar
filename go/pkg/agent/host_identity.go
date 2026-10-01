package agent

import "net"

type hostInterface struct {
	net.Interface
	addresses []net.Addr
}

// Only report the interface that owns the announced IP. Enumerating every MAC
// would also claim bridges, guest veths and unrelated network namespaces.
func hostInterfaceMACs(hostIP string) []string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	local := make([]hostInterface, 0, len(interfaces))
	for _, iface := range interfaces {
		addresses, err := iface.Addrs()
		if err == nil {
			local = append(local, hostInterface{Interface: iface, addresses: addresses})
		}
	}
	return selectHostInterfaceMACs(net.ParseIP(hostIP), local)
}

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
