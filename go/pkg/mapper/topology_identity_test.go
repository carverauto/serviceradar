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
