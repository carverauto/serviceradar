package mapper

import (
	"testing"
	"time"

	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestMacFromDot1qFDBOIDExtractsTrailingMAC(t *testing.T) {
	t.Parallel()

	// dot1q index is <fdbId>.<6 MAC octets>; a dot1d-style first-six parse
	// would misread the fdbId (100) as the first MAC octet.
	oid := oidDot1qTpFdbPort + ".100.170.187.204.221.238.98"
	mac, fdbID, ok := macFromDot1qFDBOID(oid)
	require.True(t, ok)
	assert.Equal(t, "aa:bb:cc:dd:ee:62", mac)
	assert.Equal(t, int32(100), fdbID)
}

func TestMacFromDot1qFDBOIDRejectsShortIndex(t *testing.T) {
	t.Parallel()

	// Only six index components: a bare MAC without the fdbId prefix.
	oid := oidDot1qTpFdbPort + ".170.187.204.221.238.98"
	_, _, ok := macFromDot1qFDBOID(oid)
	assert.False(t, ok)
}

func TestDot1qFDBEntriesFromPDUsTagsVLAN(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	pdus := []gosnmp.SnmpPDU{
		{
			Name:  oidDot1qTpFdbPort + ".2.170.187.204.221.238.1",
			Type:  gosnmp.Integer,
			Value: 4,
		},
		{
			// Non-positive port rows are dropped.
			Name:  oidDot1qTpFdbPort + ".2.170.187.204.221.238.2",
			Type:  gosnmp.Integer,
			Value: 0,
		},
	}

	entries := engine.dot1qFDBEntriesFromPDUs(pdus)
	require.Len(t, entries, 1)
	assert.Equal(t, "aa:bb:cc:dd:ee:01", entries[0].mac)
	assert.Equal(t, int32(4), entries[0].bridgePort)
	assert.Equal(t, int32(2), entries[0].vlanID)
}

func TestBridgeIfIndexByMACFromFDBEntriesMergesDot1dAndDot1q(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	bridgePorts := map[int32]int32{
		1: 7,
		2: 8,
	}
	entries := []fdbEntry{
		// dot1d row for a MAC also present as a dot1q VLAN duplicate on the
		// same port: merged cleanly, VLAN association kept.
		{mac: "aa:bb:cc:dd:ee:01", bridgePort: 1},
		{mac: "aa:bb:cc:dd:ee:01", bridgePort: 1, vlanID: 20},
		// dot1q-only MAC.
		{mac: "aa:bb:cc:dd:ee:02", bridgePort: 2, vlanID: 30},
		// MAC seen on two different ports remains ambiguous and is dropped.
		{mac: "aa:bb:cc:dd:ee:03", bridgePort: 1},
		{mac: "aa:bb:cc:dd:ee:03", bridgePort: 2, vlanID: 30},
	}

	bridgeIfByMAC, fdbMacCountByIf, vlanByMAC := engine.bridgeIfIndexByMACFromFDBEntries(bridgePorts, entries)

	assert.Equal(t, int32(7), bridgeIfByMAC["aabbccddee01"])
	assert.Equal(t, int32(8), bridgeIfByMAC["aabbccddee02"])
	assert.NotContains(t, bridgeIfByMAC, "aabbccddee03")
	assert.NotContains(t, vlanByMAC, "aabbccddee03")

	assert.Equal(t, int32(20), vlanByMAC["aabbccddee01"])
	assert.Equal(t, int32(30), vlanByMAC["aabbccddee02"])

	// VLAN-duplicate rows for the same (mac, ifIndex) count once.
	assert.Equal(t, 2, fdbMacCountByIf[7])
	assert.Equal(t, 2, fdbMacCountByIf[8])
}

func TestBridgeIfIndexByMACFromFDBEntriesUsesPreResolvedIfIndex(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	bridgePorts := map[int32]int32{1: 7}
	entries := []fdbEntry{
		// Per-VLAN context rows arrive with the ifIndex already resolved by
		// that context's base-port map; the shared map must not override it.
		{mac: "aa:bb:cc:dd:ee:04", bridgePort: 1, vlanID: 40, ifIndex: 9},
	}

	bridgeIfByMAC, _, vlanByMAC := engine.bridgeIfIndexByMACFromFDBEntries(bridgePorts, entries)

	assert.Equal(t, int32(9), bridgeIfByMAC["aabbccddee04"])
	assert.Equal(t, int32(40), vlanByMAC["aabbccddee04"])
}

func TestSweepVLANCommunityFDBEntriesStopsAtBudget(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}
	creds := &SNMPCredentials{
		Version:               SNMPVersion2c,
		Community:             "public",
		VLANCommunityIndexing: true,
	}

	fakeNow := time.Unix(0, 0)
	now := func() time.Time { return fakeNow }

	walked := make([]int32, 0, 4)
	walk := func(_ string, _ *SNMPCredentials, vlanID int32) []fdbEntry {
		walked = append(walked, vlanID)
		// Each VLAN context is slow: 6s per walk exceeds the 10s aggregate
		// budget after two contexts.
		fakeNow = fakeNow.Add(6 * time.Second)
		return []fdbEntry{{mac: "aa:bb:cc:dd:ee:01", bridgePort: 1, vlanID: vlanID, ifIndex: 7}}
	}

	entries := engine.sweepVLANCommunityFDBEntries("10.0.0.1", creds, []int32{1, 2, 3, 4}, walk, now)

	assert.Equal(t, []int32{1, 2}, walked)
	assert.Len(t, entries, 2)
}

func TestResolveVLANContextFDBEntriesDropsUnmappedPorts(t *testing.T) {
	t.Parallel()

	entries := []fdbEntry{
		{mac: "aa:bb:cc:dd:ee:01", bridgePort: 1},
		{mac: "aa:bb:cc:dd:ee:02", bridgePort: 2},
	}

	resolved := resolveVLANContextFDBEntries(entries, map[int32]int32{1: 7}, 30)
	require.Len(t, resolved, 1)
	assert.Equal(t, "aa:bb:cc:dd:ee:01", resolved[0].mac)
	assert.Equal(t, int32(7), resolved[0].ifIndex)
	assert.Equal(t, int32(30), resolved[0].vlanID)

	// A VLAN context without its own base-port map drops every entry rather
	// than leaving ifIndex 0 for the reducer's global-map fallback:
	// context-local bridge-port numbering differs from the global context.
	assert.Empty(t, resolveVLANContextFDBEntries(entries, nil, 30))
	assert.Empty(t, resolveVLANContextFDBEntries(entries, map[int32]int32{}, 30))
}

func TestVLANCommunityWalkEnabledRequiresOptIn(t *testing.T) {
	t.Parallel()

	assert.False(t, vlanCommunityWalkEnabled(nil))
	// Default-off: a plain v2c community credential never triggers per-VLAN walks.
	assert.False(t, vlanCommunityWalkEnabled(&SNMPCredentials{
		Version:   SNMPVersion2c,
		Community: "public",
	}))
	// v3 has no community indexing.
	assert.False(t, vlanCommunityWalkEnabled(&SNMPCredentials{
		Version:               SNMPVersion3,
		Username:              "user",
		VLANCommunityIndexing: true,
	}))
	// Opted-in v1/v2c with a community enables the walk.
	assert.True(t, vlanCommunityWalkEnabled(&SNMPCredentials{
		Version:               SNMPVersion2c,
		Community:             "public",
		VLANCommunityIndexing: true,
	}))
	assert.True(t, vlanCommunityWalkEnabled(&SNMPCredentials{
		Version:               SNMPVersion1,
		Community:             "public",
		VLANCommunityIndexing: true,
	}))
	// An empty community cannot be VLAN-indexed.
	assert.False(t, vlanCommunityWalkEnabled(&SNMPCredentials{
		Version:               SNMPVersion2c,
		Community:             "  ",
		VLANCommunityIndexing: true,
	}))
}

func TestEffectiveSNMPCredentialsForTargetAppliesTargetOverride(t *testing.T) {
	t.Parallel()

	assert.Nil(t, effectiveSNMPCredentialsForTarget(nil, "10.0.0.1"))
	assert.Nil(t, effectiveSNMPCredentialsForTarget(&DiscoveryJob{Params: &DiscoveryParams{}}, "10.0.0.1"))

	targetCreds := &SNMPCredentials{
		Version:               SNMPVersion2c,
		Community:             "special",
		VLANCommunityIndexing: true,
	}
	job := &DiscoveryJob{
		Params: &DiscoveryParams{
			Credentials: &SNMPCredentials{
				Version:   SNMPVersion2c,
				Community: "public",
				TargetSpecific: map[string]*SNMPCredentials{
					"10.0.0.1": targetCreds,
				},
			},
		},
	}

	assert.Same(t, targetCreds, effectiveSNMPCredentialsForTarget(job, "10.0.0.1"))
	assert.Same(t, job.Params.Credentials, effectiveSNMPCredentialsForTarget(job, "10.0.0.2"))
	assert.False(t, vlanCommunityWalkEnabled(effectiveSNMPCredentialsForTarget(job, "10.0.0.2")))
	assert.True(t, vlanCommunityWalkEnabled(effectiveSNMPCredentialsForTarget(job, "10.0.0.1")))
}
