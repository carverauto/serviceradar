package mapper

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBuildSNMPL2LinksFromNeighborsRequiresFDBPortMapping(t *testing.T) {
	t.Parallel()

	neighbors := []arpNeighbor{
		{
			ifIndex:       5,
			ip:            "192.168.1.50",
			mac:           "aa:bb:cc:dd:ee:01",
			fdbPortMapped: false,
		},
		{
			ifIndex:       7,
			ip:            "192.168.1.51",
			mac:           "aa:bb:cc:dd:ee:02",
			fdbPortMapped: true,
		},
	}

	links := buildSNMPL2LinksFromNeighbors("sr:farm01", "192.168.1.1", "disc-1", neighbors)
	require.Len(t, links, 1)

	link := links[0]
	assert.Equal(t, int32(7), link.LocalIfIndex)
	assert.Equal(t, "192.168.1.51", link.NeighborMgmtAddr)
	assert.Equal(t, "aa:bb:cc:dd:ee:02", link.NeighborChassisID)
	assert.Equal(t, "snmp-arp-fdb", link.Metadata["source"])
	assert.Equal(t, "true", link.Metadata["fdb_port_mapped"])
}

func TestBuildSNMPL2LinksFromNeighborsDeduplicatesIdenticalEvidence(t *testing.T) {
	t.Parallel()

	neighbors := []arpNeighbor{
		{
			ifIndex:       23,
			ip:            "192.168.10.96",
			mac:           "aa:bb:cc:dd:ee:ff",
			fdbPortMapped: true,
		},
		{
			ifIndex:       23,
			ip:            "192.168.10.96",
			mac:           "AA:BB:CC:DD:EE:FF",
			fdbPortMapped: true,
		},
	}

	links := buildSNMPL2LinksFromNeighbors("sr:aruba", "192.168.10.154", "disc-2", neighbors)
	require.Len(t, links, 1)
	assert.Equal(t, "192.168.10.96", links[0].NeighborMgmtAddr)
}

func TestBuildSNMPL2LinksFromNeighborsRejectsInvalidIfIndex(t *testing.T) {
	t.Parallel()

	neighbors := []arpNeighbor{
		{
			ifIndex:       0,
			ip:            "192.168.1.77",
			mac:           "aa:bb:cc:dd:ee:77",
			fdbPortMapped: true,
		},
	}

	links := buildSNMPL2LinksFromNeighbors("sr:farm01", "192.168.1.1", "disc-3", neighbors)
	assert.Len(t, links, 0)
}
