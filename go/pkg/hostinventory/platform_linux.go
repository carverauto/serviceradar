//go:build linux

package hostinventory

import "net"

const sysfsNetRoot = "/sys/class/net"

func platformClassify(iface net.Interface) Classification {
	return ClassifySysfs(sysfsNetRoot, iface)
}
