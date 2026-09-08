package mapper

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNormalizeTopologyLinkNeighborIdentity(t *testing.T) {
	t.Parallel()

	link := &TopologyLink{
		NeighborChassisID:  "aa:bb:cc:dd:ee:ff",
		NeighborPortID:     "Gi1/0/24",
		NeighborPortDescr:  "uplink",
		NeighborSystemName: "agg-switch",
		Metadata: map[string]string{
			"neighbor_mgmt_addr": "192.168.10.154",
		},
	}

	identity := NormalizeTopologyLinkNeighborIdentity(link)
	if assert.NotNil(t, identity) {
		assert.Equal(t, "192.168.10.154", identity.ManagementIP)
		assert.Equal(t, "aa:bb:cc:dd:ee:ff", identity.ChassisID)
		assert.Equal(t, "Gi1/0/24", identity.PortID)
		assert.Equal(t, "uplink", identity.PortDescr)
		assert.Equal(t, "agg-switch", identity.SystemName)
	}

	assert.Equal(t, "192.168.10.154", link.NeighborMgmtAddr)
	assert.NotNil(t, link.NeighborIdentity)
}

func TestNormalizeTopologyLinkNeighborIdentityReturnsNilWithoutEvidence(t *testing.T) {
	t.Parallel()

	link := &TopologyLink{Metadata: map[string]string{}}
	identity := NormalizeTopologyLinkNeighborIdentity(link)
	assert.Nil(t, identity)
	assert.Nil(t, link.NeighborIdentity)
}

func TestCanonicalMACLabel(t *testing.T) {
	t.Parallel()

	const canonical = "d0:21:f9:d2:e1:6d"

	for _, variant := range []string{
		"d021f9d2e16d",
		"d0:21:f9:d2:e1:6d",
		"D0-21-F9-D2-E1-6D",
		"d021.f9d2.e16d",
		"D0:21:F9:D2:E1:6D",
	} {
		assert.Equalf(t, canonical, canonicalMACLabel(variant), "variant %q", variant)
	}

	// Distinct MACs (off-by-one byte) stay distinct.
	assert.NotEqual(t, canonicalMACLabel("d0:21:f9:d2:e1:6c"), canonicalMACLabel("d0:21:f9:d2:e1:6d"))

	// Non-MAC labels are returned unchanged.
	for _, label := range []string{"Gi1/0/24", "Slot: 0 Port: 22 Gigabit - Level", "ifindex:22", "uplink", ""} {
		assert.Equalf(t, label, canonicalMACLabel(label), "label %q", label)
	}
}

func TestNormalizeTopologyLinkNeighborIdentityCanonicalizesMACPortID(t *testing.T) {
	t.Parallel()

	// The same neighbor port-id MAC arriving in different encodings must produce
	// the same canonical PortID/ChassisID so core keys one Interface vertex.
	a := &TopologyLink{NeighborChassisID: "d021f9d2e16d", NeighborPortID: "d021f9d2e16d"}
	b := &TopologyLink{NeighborChassisID: "d0:21:f9:d2:e1:6d", NeighborPortID: "d0:21:f9:d2:e1:6d"}

	ia := NormalizeTopologyLinkNeighborIdentity(a)
	ib := NormalizeTopologyLinkNeighborIdentity(b)

	if assert.NotNil(t, ia) && assert.NotNil(t, ib) {
		assert.Equal(t, "d0:21:f9:d2:e1:6d", ia.PortID)
		assert.Equal(t, ia.PortID, ib.PortID)
		assert.Equal(t, ia.ChassisID, ib.ChassisID)
	}
}
