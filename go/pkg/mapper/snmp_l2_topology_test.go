package mapper

import (
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

var errNoCDP = errors.New("no cdp")

const testStringTrue = "true"

func TestPublishTopologyLinksPublishesCandidateOnlyAttachments(t *testing.T) {
	t.Parallel()

	ctx := t.Context()
	publisher := &recordingPublisher{}
	engine := &DiscoveryEngine{publisher: publisher, logger: logger.NewTestLogger()}
	job := &DiscoveryJob{
		ID:     "disc-test",
		ctx:    ctx,
		Params: &DiscoveryParams{},
		Results: &DiscoveryResults{
			TopologyLinks: []*TopologyLink{},
		},
	}

	links := []*TopologyLink{
		{
			Protocol:         "SNMP-L2",
			LocalDeviceIP:    "192.168.10.1",
			LocalDeviceID:    "sr:tonka01",
			NeighborMgmtAddr: "192.168.10.154",
			Metadata: map[string]string{
				"candidate_only": testStringTrue,
			},
		},
		{
			Protocol:         "LLDP",
			LocalDeviceIP:    "192.168.10.154",
			LocalDeviceID:    "sr:aruba",
			NeighborMgmtAddr: "192.168.10.1",
			Metadata:         map[string]string{},
		},
	}

	engine.publishTopologyLinks(job, links, "192.168.10.1", "SNMP-L2")

	// candidate_only link remains marked for recursive targeting and is also
	// published downstream so topology can surface endpoint attachments.
	require.Len(t, job.Results.TopologyLinks, 2)
	require.Len(t, publisher.topologyLinks, 2)
	publishedNeighbors := []string{
		publisher.topologyLinks[0].NeighborMgmtAddr,
		publisher.topologyLinks[1].NeighborMgmtAddr,
	}
	assert.ElementsMatch(t, []string{"192.168.10.1", "192.168.10.154"}, publishedNeighbors)
}

func TestPublishTopologyEvidencePublishesSNMPL2EvenWhenLLDPPresent(t *testing.T) {
	t.Parallel()

	publisher := &recordingPublisher{}
	engine := &DiscoveryEngine{publisher: publisher, logger: logger.NewTestLogger()}
	job := &DiscoveryJob{
		ID:     "disc-topo",
		ctx:    context.Background(),
		Params: &DiscoveryParams{},
		Results: &DiscoveryResults{
			TopologyLinks: []*TopologyLink{},
		},
	}

	lldpLinks := []*TopologyLink{
		{
			Protocol:         "LLDP",
			LocalDeviceIP:    "192.168.1.87",
			LocalDeviceID:    "sr:agg",
			LocalIfIndex:     8,
			NeighborMgmtAddr: "192.168.1.131",
			Metadata:         map[string]string{},
		},
	}
	snmpL2Links := []*TopologyLink{
		{
			Protocol:         "SNMP-L2",
			LocalDeviceIP:    "192.168.1.87",
			LocalDeviceID:    "sr:agg",
			LocalIfIndex:     7,
			NeighborMgmtAddr: "192.168.1.138",
			Metadata:         map[string]string{},
		},
	}

	engine.publishTopologyEvidence(
		job,
		"192.168.1.87",
		lldpLinks,
		nil,
		nil,
		errNoCDP,
		snmpL2Links,
		nil,
	)

	// Both LLDP and SNMP-L2 evidence must be published in a single scan pass.
	require.Len(t, publisher.topologyLinks, 2)
	require.Len(t, job.Results.TopologyLinks, 2)
	assert.Equal(t, "LLDP", publisher.topologyLinks[0].Protocol)
	assert.Equal(t, "SNMP-L2", publisher.topologyLinks[1].Protocol)
}

type recordingPublisher struct {
	topologyLinks []*TopologyLink
}

func (r *recordingPublisher) PublishDevice(_ context.Context, _ *DiscoveredDevice) error { return nil }
func (r *recordingPublisher) PublishInterface(_ context.Context, _ *DiscoveredInterface) error {
	return nil
}
func (r *recordingPublisher) PublishTopologyLink(_ context.Context, link *TopologyLink) error {
	r.topologyLinks = append(r.topologyLinks, link)
	return nil
}

func TestBuildSNMPL2LinksFromNeighborsKeepsARPOnlyAsCandidateOnly(t *testing.T) {
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
	require.Len(t, links, 2)

	var fdbLink *TopologyLink
	var candidateLink *TopologyLink

	for _, link := range links {
		if link.Metadata["candidate_only"] == testStringTrue {
			candidateLink = link
		} else {
			fdbLink = link
		}
	}

	require.NotNil(t, fdbLink)
	require.NotNil(t, candidateLink)

	assert.Equal(t, int32(7), fdbLink.LocalIfIndex)
	assert.Equal(t, "192.168.1.51", fdbLink.NeighborMgmtAddr)
	assert.Equal(t, "aa:bb:cc:dd:ee:02", fdbLink.NeighborChassisID)
	assert.Equal(t, "snmp-arp-fdb", fdbLink.Metadata["source"])
	assert.Equal(t, testStringTrue, fdbLink.Metadata["fdb_port_mapped"])
	assert.Equal(t, "inferred", fdbLink.Metadata["evidence_class"])
	assert.Equal(t, "medium", fdbLink.Metadata["confidence_tier"])

	assert.Equal(t, int32(0), candidateLink.LocalIfIndex)
	assert.Equal(t, "192.168.1.50", candidateLink.NeighborMgmtAddr)
	assert.Equal(t, "snmp-arp-only", candidateLink.Metadata["source"])
	assert.Equal(t, "false", candidateLink.Metadata["fdb_port_mapped"])
	assert.Equal(t, "endpoint-attachment", candidateLink.Metadata["evidence_class"])
	assert.Equal(t, "low", candidateLink.Metadata["confidence_tier"])
	assert.Equal(t, testStringTrue, candidateLink.Metadata["candidate_only"])
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
	assert.Empty(t, links)
}

func TestSelectDensePortNeighborsKeepsKnownAndBoundsUnknown(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	neighbors := []arpNeighbor{
		{ifIndex: 9, ip: "192.168.10.40", mac: "aa:bb:cc:dd:ee:40", fdbMacCount: 12, neighborKnown: true},
		{ifIndex: 9, ip: "192.168.10.30", mac: "aa:bb:cc:dd:ee:30", fdbMacCount: 12, neighborKnown: false},
		{ifIndex: 9, ip: "192.168.10.10", mac: "aa:bb:cc:dd:ee:10", fdbMacCount: 12, neighborKnown: false},
		{ifIndex: 9, ip: "192.168.10.20", mac: "aa:bb:cc:dd:ee:20", fdbMacCount: 12, neighborKnown: false},
		{ifIndex: 7, ip: "192.168.1.2", mac: "aa:bb:cc:dd:ee:02", fdbMacCount: 2, neighborKnown: false},
	}

	selected := engine.selectDensePortNeighbors(neighbors)

	seen := make(map[string]bool, len(selected))
	for _, n := range selected {
		seen[n.ip] = true
	}

	assert.True(t, seen["192.168.10.40"], "known dense-port neighbor should be retained")
	assert.True(t, seen["192.168.10.10"], "lowest unknown candidate should be retained")
	assert.True(t, seen["192.168.10.20"], "second unknown candidate should be retained")
	assert.False(t, seen["192.168.10.30"], "unknown dense-port neighbors should be bounded")
	assert.True(t, seen["192.168.1.2"], "low-density neighbors should be retained")
}

func TestKnownDeviceIPv4SetIncludesScanQueueTargets(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{},
		},
		scanQueue: []string{"192.168.10.154", "not-an-ip"},
	}

	known := engine.knownDeviceIPv4Set(job)

	assert.True(t, known["192.168.10.154"])
	assert.False(t, known["not-an-ip"])
}

func TestParseIPToPhysicalSuffixWithLengthEncoding(t *testing.T) {
	t.Parallel()

	oid := ".1.3.6.1.2.1.4.35.1.4.22.1.4.192.168.10.154"
	ifIndex, ip, ok := parseIPToPhysicalSuffix(oid)
	require.True(t, ok)
	assert.Equal(t, int32(22), ifIndex)
	assert.Equal(t, "192.168.10.154", ip)
}

func TestParseIPToPhysicalSuffixWithDirectIPv4Encoding(t *testing.T) {
	t.Parallel()

	oid := ".1.3.6.1.2.1.4.35.1.4.7.1.192.168.10.1"
	ifIndex, ip, ok := parseIPToPhysicalSuffix(oid)
	require.True(t, ok)
	assert.Equal(t, int32(7), ifIndex)
	assert.Equal(t, "192.168.10.1", ip)
}
