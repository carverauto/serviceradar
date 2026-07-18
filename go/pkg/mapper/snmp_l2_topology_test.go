package mapper

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

var errNoCDP = errors.New("no cdp")

const testStringTrue = "true"

func TestPublishTopologyLinksSkipsPublishingCandidateOnlyAttachments(t *testing.T) {
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

	// candidate_only links remain in the in-memory discovery results so they can
	// seed recursive targets, but they are not published downstream as
	// first-class topology evidence.
	require.Len(t, job.Results.TopologyLinks, 2)
	require.Len(t, publisher.topologyLinks, 1)
	publishedNeighbors := []string{
		publisher.topologyLinks[0].NeighborMgmtAddr,
	}
	assert.ElementsMatch(t, []string{"192.168.10.1"}, publishedNeighbors)
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
	assert.Equal(t, evidenceClassInferredSegment, fdbLink.Metadata["evidence_class"])
	assert.Equal(t, "ATTACHED_TO", fdbLink.Metadata["relation_family"])
	assert.Equal(t, "medium", fdbLink.Metadata["confidence_tier"])

	assert.Equal(t, int32(0), candidateLink.LocalIfIndex)
	assert.Equal(t, "192.168.1.50", candidateLink.NeighborMgmtAddr)
	assert.Equal(t, "snmp-arp-only", candidateLink.Metadata["source"])
	assert.Equal(t, "false", candidateLink.Metadata["fdb_port_mapped"])
	assert.Equal(t, evidenceClassObservedOnly, candidateLink.Metadata["evidence_class"])
	assert.Equal(t, "OBSERVED_TO", candidateLink.Metadata["relation_family"])
	assert.Equal(t, "low", candidateLink.Metadata["confidence_tier"])
	assert.Equal(t, testStringTrue, candidateLink.Metadata["candidate_only"])
}

func TestBuildSNMPL2LinksFromNeighborsSkipsKnownFdbNeighborWithoutIdentity(t *testing.T) {
	t.Parallel()

	neighbors := []arpNeighbor{
		{
			ifIndex:            9,
			ip:                 "192.168.1.62",
			mac:                "aa:bb:cc:dd:ee:62",
			fdbPortMapped:      true,
			neighborKnown:      true,
			neighborIdentified: false,
		},
		{
			ifIndex:            11,
			ip:                 "192.168.1.63",
			mac:                "aa:bb:cc:dd:ee:63",
			fdbPortMapped:      true,
			neighborKnown:      true,
			neighborIdentified: true,
		},
	}

	links := buildSNMPL2LinksFromNeighbors("sr:farm01", "192.168.1.1", "disc-4", neighbors)
	require.Len(t, links, 1)
	assert.Equal(t, "192.168.1.63", links[0].NeighborMgmtAddr)
	assert.Equal(t, int32(11), links[0].LocalIfIndex)
}

func TestBuildSNMPL2LinksFromNeighborsReadmitsCrossDeviceObservedJoin(t *testing.T) {
	t.Parallel()

	neighbors := []arpNeighbor{
		{
			// Same-device ARP+FDB known-IP-no-identity neighbors stay vetoed.
			ifIndex:            9,
			ip:                 "192.168.10.62",
			mac:                "aa:bb:cc:dd:ee:62",
			fdbPortMapped:      true,
			neighborKnown:      true,
			neighborIdentified: false,
			observedJoin:       false,
		},
		{
			// Cross-device ARP-observed joins are exempt from the veto even
			// when the IP is "known" via the recursive scan queue.
			ifIndex:            13,
			ip:                 "192.168.10.31",
			mac:                "aa:bb:cc:dd:ee:31",
			fdbPortMapped:      true,
			neighborKnown:      true,
			neighborIdentified: false,
			observedJoin:       true,
		},
	}

	links := buildSNMPL2LinksFromNeighbors("sr:aruba", "192.168.10.154", "disc-5", neighbors)
	require.Len(t, links, 1)
	assert.Equal(t, "192.168.10.31", links[0].NeighborMgmtAddr)
	assert.Equal(t, int32(13), links[0].LocalIfIndex)
	assert.Equal(t, "snmp-arp-fdb", links[0].Metadata["source"])
	assert.Equal(t, "cross_device_arp_fdb_join", links[0].Metadata["confidence_reason"])
	assert.Equal(t, "medium", links[0].Metadata["confidence_tier"])
	assert.Equal(t, evidenceClassInferredSegment, links[0].Metadata["evidence_class"])
	assert.Equal(t, "ATTACHED_TO", links[0].Metadata["relation_family"])
}

func TestBuildSNMPL2LinksFromNeighborsEmitsCrossSubnetFdbAttachment(t *testing.T) {
	t.Parallel()

	neighbors := []arpNeighbor{
		{
			ifIndex:       3,
			ip:            "192.168.2.11",
			mac:           "aa:bb:cc:dd:ee:11",
			fdbPortMapped: true,
			crossSubnet:   true,
		},
	}

	links := buildSNMPL2LinksFromNeighbors("sr:usw-pro-24", "192.168.1.131", "disc-6", neighbors)
	require.Len(t, links, 1)
	assert.Equal(t, "192.168.2.11", links[0].NeighborMgmtAddr)
	assert.Equal(t, "cross_subnet_arp_fdb_port_mapping", links[0].Metadata["confidence_reason"])
	assert.Equal(t, "medium", links[0].Metadata["confidence_tier"])
	assert.Equal(t, evidenceClassInferredSegment, links[0].Metadata["evidence_class"])
	assert.Equal(t, "ATTACHED_TO", links[0].Metadata["relation_family"])
}

func TestBuildSNMPL2LinksFromNeighborsAddsVLANMetadata(t *testing.T) {
	t.Parallel()

	neighbors := []arpNeighbor{
		{
			ifIndex:       5,
			ip:            "192.168.2.12",
			mac:           "aa:bb:cc:dd:ee:12",
			fdbPortMapped: true,
			vlanID:        100,
		},
		{
			ifIndex:       6,
			ip:            "192.168.1.13",
			mac:           "aa:bb:cc:dd:ee:13",
			fdbPortMapped: true,
		},
	}

	links := buildSNMPL2LinksFromNeighbors("sr:usw-pro-24", "192.168.1.131", "disc-7", neighbors)
	require.Len(t, links, 2)
	assert.Equal(t, "100", links[0].Metadata["vlan_id"])
	assert.NotContains(t, links[1].Metadata, "vlan_id")
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

func TestSelectDensePortNeighborsRetainsFDBBackedCandidates(t *testing.T) {
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
	require.Len(t, selected, len(neighbors))

	seen := make(map[string]bool, len(selected))
	for _, n := range selected {
		seen[n.ip] = true
	}

	assert.True(t, seen["192.168.10.40"])
	assert.True(t, seen["192.168.10.30"])
	assert.True(t, seen["192.168.10.10"])
	assert.True(t, seen["192.168.10.20"])
	assert.True(t, seen["192.168.1.2"])
}

func TestObservedFDBMappedNeighborsReusesObservedIPsAcrossDevices(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{}

	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:62", "192.168.1.62", "192.168.1.1", true)
	engine.recordObservedNeighborIPByMAC(job, "AA:BB:CC:DD:EE:62", "192.168.1.62", "192.168.1.1", true)
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:88", "192.168.1.88", "192.168.1.1", true)
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:99", "192.168.2.99", "192.168.1.1", false)

	neighbors := engine.observedFDBMappedNeighbors(
		job,
		"192.168.1.138",
		map[string]struct{}{"192.168.1": {}},
		map[string]int32{
			"aabbccddee62": 7,
			"aabbccddee88": 7,
			"aabbccddee99": 7,
		},
		map[string]int32{"aabbccddee99": 20},
		map[int32]int{7: 5},
		map[string]knownMACNeighbor{
			"aabbccddee88": {deviceID: "sr:known-switch", ip: "192.168.1.88", mac: "aa:bb:cc:dd:ee:88"},
		},
		map[string]bool{
			"192.168.1.62": false,
			"192.168.1.88": true,
		},
	)

	// Cross-subnet observed IPs are no longer excluded: 192.168.2.99 joins
	// with crossSubnet=true. The known-device MAC (ee:88) is still skipped.
	require.Len(t, neighbors, 2)

	assert.Equal(t, int32(7), neighbors[0].ifIndex)
	assert.Equal(t, "192.168.1.62", neighbors[0].ip)
	assert.Equal(t, "aabbccddee62", neighbors[0].mac)
	assert.True(t, neighbors[0].fdbPortMapped)
	assert.Equal(t, 5, neighbors[0].fdbMacCount)
	assert.False(t, neighbors[0].neighborKnown)
	assert.False(t, neighbors[0].neighborIdentified)
	assert.False(t, neighbors[0].crossSubnet)
	assert.True(t, neighbors[0].observedJoin)
	assert.Equal(t, int32(0), neighbors[0].vlanID)

	assert.Equal(t, int32(7), neighbors[1].ifIndex)
	assert.Equal(t, "192.168.2.99", neighbors[1].ip)
	assert.Equal(t, "aabbccddee99", neighbors[1].mac)
	assert.False(t, neighbors[1].neighborIdentified)
	assert.True(t, neighbors[1].crossSubnet)
	assert.True(t, neighbors[1].observedJoin)
	assert.Equal(t, int32(20), neighbors[1].vlanID)
}

func TestObservedFDBMappedNeighborsPrefersSubnetLocalMappings(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{}

	// One MAC observed with disagreeing IPs: the mapping recorded by the L3
	// owner of the endpoint's subnet wins over remote ARP hearsay.
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:70", "10.0.0.5", "192.168.1.1", false)
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:70", "192.168.1.70", "192.168.1.1", true)
	// A MAC with only non-local mappings still falls back to them.
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:71", "10.0.0.9", "192.168.1.1", false)

	neighbors := engine.observedFDBMappedNeighbors(
		job,
		"192.168.1.138",
		map[string]struct{}{"192.168.1": {}},
		map[string]int32{
			"aabbccddee70": 3,
			"aabbccddee71": 4,
		},
		nil,
		map[int32]int{3: 1, 4: 1},
		map[string]knownMACNeighbor{},
		map[string]bool{},
	)

	require.Len(t, neighbors, 2)
	assert.Equal(t, "192.168.1.70", neighbors[0].ip)
	assert.False(t, neighbors[0].crossSubnet)
	assert.Equal(t, "10.0.0.9", neighbors[1].ip)
	assert.True(t, neighbors[1].crossSubnet)
}

func TestRecordObservedNeighborIPByMACSubnetLocalIsSticky(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{}

	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:72", "192.168.1.72", "192.168.1.9", false)
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:72", "192.168.1.72", "192.168.1.1", true)
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:72", "192.168.1.72", "192.168.1.9", false)

	observed := engine.observedNeighborIPsByMAC(job)
	require.Len(t, observed["aabbccddee72"], 1)
	assert.Equal(t, "192.168.1.72", observed["aabbccddee72"][0].ip)
	assert.True(t, observed["aabbccddee72"][0].subnetLocal)
	// Observers accumulate (deduplicated, sorted) across records.
	assert.Equal(t, []string{"192.168.1.1", "192.168.1.9"}, observed["aabbccddee72"][0].observers)
}

func TestObservedFDBMappedNeighborsRequiresCrossDeviceObserver(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{}
	targetIP := "192.168.1.138"

	// Only the target itself observed this mapping (its own ARP rows): the
	// observed join must not produce a twin of the direct ARP+FDB neighbor.
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:80", "192.168.1.80", targetIP, true)

	join := func() []arpNeighbor {
		return engine.observedFDBMappedNeighbors(
			job,
			targetIP,
			map[string]struct{}{"192.168.1": {}},
			map[string]int32{"aabbccddee80": 5},
			nil,
			map[int32]int{5: 1},
			map[string]knownMACNeighbor{},
			map[string]bool{},
		)
	}

	assert.Empty(t, join())

	// A second, genuinely cross-device observer makes the mapping joinable.
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:80", "192.168.1.80", "192.168.1.1", true)

	neighbors := join()
	require.Len(t, neighbors, 1)
	assert.Equal(t, "192.168.1.80", neighbors[0].ip)
	assert.True(t, neighbors[0].observedJoin)
}

func TestSelfObservedARPFDBTwinStaysVetoed(t *testing.T) {
	t.Parallel()

	// End-to-end composition of a single device's walk: its own ARP row for a
	// known-IP, unidentified neighbor is vetoed on the direct path and must
	// NOT resurface through the observed-join path as a cross-device twin.
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{}
	targetIP := "192.168.1.138"
	localSubnets := map[string]struct{}{"192.168.1": {}}
	bridgeIfByMAC := map[string]int32{"aabbccddee90": 9}
	fdbMacCountByIf := map[int32]int{9: 1}
	knownNeighborsByMAC := map[string]knownMACNeighbor{}
	knownNeighborIPs := map[string]bool{"192.168.1.90": true}

	// appendNeighborEvidence-equivalent: record the target's own ARP row with
	// itself as observer and produce the direct FDB-mapped neighbor.
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:90", "192.168.1.90", targetIP, true)
	direct := arpNeighbor{
		ifIndex:            9,
		ip:                 "192.168.1.90",
		mac:                "aa:bb:cc:dd:ee:90",
		fdbPortMapped:      true,
		fdbMacCount:        1,
		neighborKnown:      true,
		neighborIdentified: false,
	}

	observed := engine.observedFDBMappedNeighbors(
		job,
		targetIP,
		localSubnets,
		bridgeIfByMAC,
		nil,
		fdbMacCountByIf,
		knownNeighborsByMAC,
		knownNeighborIPs,
	)

	neighbors := make([]arpNeighbor, 0, len(observed)+1)
	neighbors = append(neighbors, direct)
	neighbors = append(neighbors, observed...)

	links := buildSNMPL2LinksFromNeighbors("sr:switch", targetIP, "disc-twin", neighbors)
	assert.Empty(t, links)
}

func TestObservedFDBMappedNeighborsSkipsHighFanoutPorts(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{}

	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:50", "192.168.1.50", "192.168.1.1", true)

	// A port holding more MACs than the bound is a trunk/uplink, never an
	// endpoint attachment point for the observed join.
	neighbors := engine.observedFDBMappedNeighbors(
		job,
		"192.168.1.138",
		map[string]struct{}{"192.168.1": {}},
		map[string]int32{"aabbccddee50": 7},
		nil,
		map[int32]int{7: maxObservedJoinPortMACs + 1},
		map[string]knownMACNeighbor{},
		map[string]bool{},
	)
	assert.Empty(t, neighbors)
}

func TestObservedFDBMappedNeighborsSkipsSharedMACsWithManyIPs(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{}

	// One MAC mapping to more IPs than the cap (all subnet-local, all
	// cross-device observed) is a shared/virtual/proxy-ARP MAC: skipped.
	for i := 1; i <= maxObservedJoinIPsPerMAC+1; i++ {
		engine.recordObservedNeighborIPByMAC(
			job, "aa:bb:cc:dd:ee:60", fmt.Sprintf("192.168.1.%d", i), "192.168.1.1", true)
	}
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:61", "192.168.1.61", "192.168.1.1", true)

	neighbors := engine.observedFDBMappedNeighbors(
		job,
		"192.168.1.138",
		map[string]struct{}{"192.168.1": {}},
		map[string]int32{
			"aabbccddee60": 3,
			"aabbccddee61": 4,
		},
		nil,
		map[int32]int{3: 5, 4: 1},
		map[string]knownMACNeighbor{},
		map[string]bool{},
	)
	require.Len(t, neighbors, 1)
	assert.Equal(t, "192.168.1.61", neighbors[0].ip)
}

func TestReconcileObservedFDBJoinsEmitsLateARPJoinOnce(t *testing.T) {
	t.Parallel()

	publisher := &recordingPublisher{}
	engine := &DiscoveryEngine{publisher: publisher, logger: logger.NewTestLogger()}
	job := &DiscoveryJob{
		ID:     "disc-reconcile",
		ctx:    context.Background(),
		Params: &DiscoveryParams{},
		Results: &DiscoveryResults{
			TopologyLinks: []*TopologyLink{},
		},
	}

	// FDB owner walked first: its join context is cached while the shared ARP
	// map is still empty, so its own walk emitted nothing.
	engine.recordObservedJoinContext(job, "192.168.10.154", &observedJoinContext{
		localDeviceID:   "sr:aruba",
		localSubnets:    map[string]struct{}{"192.168.10": {}},
		bridgeIfByMAC:   map[string]int32{"aabbccddee31": 13},
		vlanByMAC:       map[string]int32{},
		fdbMacCountByIf: map[int32]int{13: 1},
	})

	// The ARP owner walked later and recorded the mapping.
	engine.recordObservedNeighborIPByMAC(job, "aa:bb:cc:dd:ee:31", "192.168.10.31", "192.168.10.1", true)

	engine.reconcileObservedFDBJoins(job)

	require.Len(t, publisher.topologyLinks, 1)
	link := publisher.topologyLinks[0]
	assert.Equal(t, "sr:aruba", link.LocalDeviceID)
	assert.Equal(t, int32(13), link.LocalIfIndex)
	assert.Equal(t, "192.168.10.31", link.NeighborMgmtAddr)
	assert.Equal(t, "cross_device_arp_fdb_join", link.Metadata["confidence_reason"])
	assert.Equal(t, "medium", link.Metadata["confidence_tier"])
	require.Len(t, job.Results.TopologyLinks, 1)

	// Re-running must not duplicate the already-published link.
	engine.reconcileObservedFDBJoins(job)
	assert.Len(t, publisher.topologyLinks, 1)
	assert.Len(t, job.Results.TopologyLinks, 1)
}

func TestBuildSNMPL2LinksFromNeighborsFillsCandidateCapSameSubnetFirst(t *testing.T) {
	t.Parallel()

	// Cross-subnet ARP-only rows arrive FIRST but must not displace
	// same-subnet candidates from the cap.
	neighbors := make([]arpNeighbor, 0, maxSNMPARPCandidateNeighbors+3)
	for i := 0; i < 3; i++ {
		neighbors = append(neighbors, arpNeighbor{
			ip:          fmt.Sprintf("10.0.0.%d", i+1),
			mac:         fmt.Sprintf("aa:bb:cc:dd:01:%02x", i),
			crossSubnet: true,
		})
	}
	for i := 0; i < maxSNMPARPCandidateNeighbors-1; i++ {
		neighbors = append(neighbors, arpNeighbor{
			ip:  fmt.Sprintf("192.168.1.%d", i+1),
			mac: fmt.Sprintf("aa:bb:cc:dd:02:%02x", i),
		})
	}

	links := buildSNMPL2LinksFromNeighbors("sr:switch", "192.168.1.1", "disc-cap", neighbors)
	require.Len(t, links, maxSNMPARPCandidateNeighbors)

	crossSubnetIPs := make([]string, 0, 1)
	sameSubnetCount := 0
	for _, link := range links {
		if strings.HasPrefix(link.NeighborMgmtAddr, "10.0.0.") {
			crossSubnetIPs = append(crossSubnetIPs, link.NeighborMgmtAddr)
			continue
		}
		sameSubnetCount++
	}

	// All same-subnet candidates admitted; the single leftover cap slot goes
	// to the FIRST cross-subnet row (relative order preserved).
	assert.Equal(t, maxSNMPARPCandidateNeighbors-1, sameSubnetCount)
	assert.Equal(t, []string{"10.0.0.1"}, crossSubnetIPs)
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
