package mapper

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestResolveLocalInterfaceName(t *testing.T) {
	t.Parallel()

	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Interfaces: []*DiscoveredInterface{
				{IfIndex: 22, IfDescr: "Slot: 0 Port: 22 Gigabit - Level"},
				{IfIndex: 7, IfName: "Gi0/7", IfDescr: "GigabitEthernet0/7"},
				{IfIndex: 5, IfAlias: "uplink-to-core"},
			},
		},
	}

	// An LLDP/CDP link that only carried a local ifindex gets its name resolved
	// from the interface table — so core keys the named vertex, not a phantom.
	link := &TopologyLink{LocalIfIndex: 22}
	resolveLocalInterfaceName(job, link)
	assert.Equal(t, "Slot: 0 Port: 22 Gigabit - Level", link.LocalIfName)

	// IfName wins over IfDescr.
	link2 := &TopologyLink{LocalIfIndex: 7}
	resolveLocalInterfaceName(job, link2)
	assert.Equal(t, "Gi0/7", link2.LocalIfName)

	// An already-named link is left untouched.
	named := &TopologyLink{LocalIfIndex: 22, LocalIfName: "explicit"}
	resolveLocalInterfaceName(job, named)
	assert.Equal(t, "explicit", named.LocalIfName)

	// IfAlias-only port: must mirror the scan (IfName->IfDescr->"Interface-N",
	// never IfAlias) so it converges with the vertex the scan keys, not a 3rd label.
	aliasOnly := &TopologyLink{LocalIfIndex: 5}
	resolveLocalInterfaceName(job, aliasOnly)
	assert.Equal(t, "Interface-5", aliasOnly.LocalIfName)

	// Unknown ifindex / no match -> stays blank (core keeps the ifindex fallback).
	miss := &TopologyLink{LocalIfIndex: 99}
	resolveLocalInterfaceName(job, miss)
	assert.Empty(t, miss.LocalIfName)

	// ifindex <= 0 is not a stable identity -> no-op.
	zero := &TopologyLink{LocalIfIndex: 0}
	resolveLocalInterfaceName(job, zero)
	assert.Empty(t, zero.LocalIfName)
}
