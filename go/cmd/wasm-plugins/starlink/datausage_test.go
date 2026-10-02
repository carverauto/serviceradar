package main

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const testDataPoolID = "pool-001"

// dataUsageSnap builds a snapshot with testTerminalA → testServiceLine
// and, when withPool is true, the service line carries testDataPoolID.
func dataUsageSnap(withPool bool) *inventorySnapshot {
	slID := ""
	if withPool {
		slID = testDataPoolID
	}
	return &inventorySnapshot{
		Terminals: []terminal{
			{ID: testTerminalA, ServiceLine: testServiceLine},
		},
		ServiceLines: map[string]serviceLine{
			testServiceLine: {Number: testServiceLine, Active: true, DataPoolID: slID},
		},
	}
}

// usageBody returns a realistic data-usage API response for testServiceLine.
// downloadPriority=12.5, uploadPriority=2.3, downloadStandard=47.8, uploadStandard=8.1, budget=100.0
func usageBody() string {
	return envelope(`{"dataUsages":[{"serviceLineNumber":"` + testServiceLine + `",` +
		`"downloadPriorityGB":12.5,"uploadPriorityGB":2.3,` +
		`"downloadStandardGB":47.8,"uploadStandardGB":8.1,"budgetGB":100.0}]}`)
}

func TestSlTerminalMapBuildsFromSnapshot(t *testing.T) {
	snap := dataUsageSnap(false)
	m := slTerminalMap(snap)
	want := terminalIDPrefix + testTerminalA
	if got := m[testServiceLine]; got != want {
		t.Fatalf("slTerminalMap[%q] = %q, want %q", testServiceLine, got, want)
	}
}

func TestPoolTerminalMapBuildsWhenPoolPresent(t *testing.T) {
	snap := dataUsageSnap(true)
	m := poolTerminalMap(snap)
	terminals := m[testDataPoolID]
	if len(terminals) != 1 || terminals[0] != terminalIDPrefix+testTerminalA {
		t.Fatalf("poolTerminalMap[%q] = %v, want one entry for terminal A", testDataPoolID, terminals)
	}
}

func TestPoolTerminalMapEmptyWhenNoPool(t *testing.T) {
	snap := dataUsageSnap(false)
	m := poolTerminalMap(snap)
	if len(m) != 0 {
		t.Fatalf("expected empty pool map, got %v", m)
	}
}

func TestQueryDataUsageReturnsRecordForKnownServiceLine(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodPost, "/data-usage/query", 200, usageBody())

	c := newAPIClient(fake, mustConfig(t, `{}`))
	slMap := map[string]string{testServiceLine: terminalIDPrefix + testTerminalA}
	now := time.Date(2026, time.January, 15, 0, 0, 0, 0, time.UTC)

	records := queryDataUsage(c, []string{testServiceLine}, slMap, "test-instance", now)

	if len(records) != 1 {
		t.Fatalf("got %d records, want 1", len(records))
	}
	r := records[0]
	if r.PayloadKind != sdk.SignalSchemaPayloadKindServiceRadarMetrics {
		t.Fatalf("payload_kind = %q, want metrics kind", r.PayloadKind)
	}
	wantIDPrefix := "starlink-datausage-" + terminalIDPrefix + testTerminalA + "-"
	if !strings.HasPrefix(r.EventID, wantIDPrefix) {
		t.Fatalf("event_id = %q, want prefix %q", r.EventID, wantIDPrefix)
	}
}

func TestQueryDataUsageIgnoresUnknownServiceLine(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodPost, "/data-usage/query", 200,
		envelope(`{"dataUsages":[{"serviceLineNumber":"SL-TST-000000-00000-99",`+
			`"downloadPriorityGB":5.0,"uploadPriorityGB":1.0,`+
			`"downloadStandardGB":10.0,"uploadStandardGB":2.0,"budgetGB":0}]}`))

	c := newAPIClient(fake, mustConfig(t, `{}`))
	// slMap does not contain the service line in the response.
	slMap := map[string]string{}
	now := time.Date(2026, time.January, 15, 0, 0, 0, 0, time.UTC)

	records := queryDataUsage(c, []string{testServiceLine}, slMap, "test-instance", now)

	if len(records) != 0 {
		t.Fatalf("got %d records for unknown service line, want 0", len(records))
	}
}

func TestQueryDataUsageReturnsNilOnAPIError(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodPost, "/data-usage/query", 500, `{"errors":["upstream error"]}`)

	c := newAPIClient(fake, mustConfig(t, `{}`))
	slMap := map[string]string{testServiceLine: terminalIDPrefix + testTerminalA}
	now := time.Date(2026, time.January, 15, 0, 0, 0, 0, time.UTC)

	records := queryDataUsage(c, []string{testServiceLine}, slMap, "test-instance", now)

	if len(records) != 0 {
		t.Fatalf("got %d records on 500 response, want 0 (best-effort skip)", len(records))
	}
}

func TestCollectDataUsageEmitsRecords(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodPost, "/data-usage/query", 200, usageBody())

	c := newAPIClient(fake, mustConfig(t, `{}`))
	snap := dataUsageSnap(false)
	now := time.Date(2026, time.January, 15, 0, 0, 0, 0, time.UTC)

	records := collectDataUsage(c, snap, "test-instance", now)

	if len(records) != 1 {
		t.Fatalf("collectDataUsage returned %d records, want 1", len(records))
	}
}

func TestCollectDataUsageSkipsEmptySnapshot(t *testing.T) {
	fake := newFakeHTTP(t)
	// No HTTP calls should happen for an empty snapshot.

	c := newAPIClient(fake, mustConfig(t, `{}`))
	snap := &inventorySnapshot{
		Terminals:    []terminal{},
		ServiceLines: map[string]serviceLine{},
	}
	now := time.Date(2026, time.January, 15, 0, 0, 0, 0, time.UTC)

	records := collectDataUsage(c, snap, "test-instance", now)

	if len(records) != 0 {
		t.Fatalf("expected no records for empty snapshot, got %d", len(records))
	}
}

func TestCollectPoolMetricsEmitsCapacityAndUsage(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/data-pools", 200,
		envelope(`{"dataPools":[{"dataPoolId":"pool-001","capacityGB":200.0}]}`))
	fake.on(http.MethodGet, "/data-pools/pool-001/usage", 200,
		envelope(`{"usedGB":85.3,"remainingGB":114.7}`))

	c := newAPIClient(fake, mustConfig(t, `{}`))
	poolMap := map[string][]string{
		testDataPoolID: {terminalIDPrefix + testTerminalA},
	}
	now := time.Date(2026, time.January, 15, 0, 0, 0, 0, time.UTC)

	records := collectPoolMetrics(c, poolMap, "test-instance", now)

	if len(records) != 1 {
		t.Fatalf("collectPoolMetrics returned %d records, want 1", len(records))
	}
	r := records[0]
	if r.PayloadKind != sdk.SignalSchemaPayloadKindServiceRadarMetrics {
		t.Fatalf("payload_kind = %q, want metrics kind", r.PayloadKind)
	}
	wantIDPrefix := "starlink-pool-" + terminalIDPrefix + testTerminalA + "-"
	if !strings.HasPrefix(r.EventID, wantIDPrefix) {
		t.Fatalf("event_id = %q, want prefix %q", r.EventID, wantIDPrefix)
	}
}

func TestCollectPoolMetricsSkipsUnsafePoolID(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/data-pools", 200,
		envelope(`{"dataPools":[]}`))

	c := newAPIClient(fake, mustConfig(t, `{}`))
	// Pool IDs that would be unsafe to interpolate into a URL path must be skipped.
	poolMap := map[string][]string{
		"../../../evil": {terminalIDPrefix + testTerminalA},
	}
	now := time.Date(2026, time.January, 15, 0, 0, 0, 0, time.UTC)

	records := collectPoolMetrics(c, poolMap, "test-instance", now)

	if len(records) != 0 {
		t.Fatalf("expected no records for unsafe pool ID, got %d", len(records))
	}
}

func TestCollectPoolMetricsEmptyWhenNoPool(t *testing.T) {
	fake := newFakeHTTP(t)
	c := newAPIClient(fake, mustConfig(t, `{}`))

	records := collectPoolMetrics(c, map[string][]string{}, "test-instance", time.Now())

	if records != nil {
		t.Fatalf("expected nil for empty pool map, got %v", records)
	}
}
