//go:build !linux

package hostinventory

import "net"

// Outside Linux the agent has no permission-free source for an interface's
// kind or MAC provenance, so it reports only what the flags say. Core treats an
// inventory without classified interfaces as unclassified and keeps using the
// announced interface's MAC (host_macs), as it did before the inventory existed.
func platformClassify(iface net.Interface) Classification {
	return flagClassification(iface)
}
