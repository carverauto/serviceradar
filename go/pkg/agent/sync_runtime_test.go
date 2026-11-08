/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/models"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"
)

// fakeSyncSourceType is an integration-neutral source type registered only in
// tests. It drives the generic runtime pipeline (registry lookup, update
// normalization, chunking, gateway streaming) without referencing any real
// integration.
const fakeSyncSourceType = "synthetic"

var (
	errFakeSyncDriverFailed = errors.New("fake sync driver failed")
	// errLongMultibyteUpstream crosses syncControlErrorMaxBytes inside a
	// multi-byte rune.
	errLongMultibyteUpstream    = errors.New(strings.Repeat("a", syncControlErrorMaxBytes-1) + strings.Repeat("é", 8))
	errShortInvalidUTF8Upstream = errors.New("502 Bad Gateway: \xff\xfebody")
)

// fakeSyncDrivers is the driver registry of a test runtime: the synthetic driver only.
func fakeSyncDrivers() syncsources.Registry {
	drivers := syncsources.Registry{}
	drivers.Register(fakeSyncSourceType, func() syncsources.SourceDriver {
		return &fakeSyncDriver{}
	})
	return drivers
}

// fakeSyncDriver emits synthetic device updates. Its behavior is configured
// through source credentials:
//
//	pages:            number of pages to emit (default 1)
//	devices_per_page: updates emitted per page (default 1)
//	fail_after_pages: fail after emitting this many pages (unset: never)
//	raw_mac:          raw MAC value attached to the first update of page 0
//	stall:            "true" blocks until the run context ends, like a hung API
type fakeSyncDriver struct{}

func (*fakeSyncDriver) Sync(ctx context.Context, run syncsources.RunContext) (int, error) {
	if run.Source.Credentials["stall"] == rawBoolTrue {
		<-ctx.Done()
		return 0, ctx.Err()
	}

	pages := fakeDriverInt(run.Source.Credentials, "pages", 1)
	perPage := fakeDriverInt(run.Source.Credentials, "devices_per_page", 1)
	failAfter := fakeDriverInt(run.Source.Credentials, "fail_after_pages", -1)

	total := 0
	deviceNumber := 0

	for page := 0; page < pages; page++ {
		if failAfter >= 0 && page == failAfter {
			return total, errFakeSyncDriverFailed
		}

		updates := make([]map[string]any, 0, perPage)
		for i := 0; i < perPage; i++ {
			deviceNumber++
			ip := fmt.Sprintf("10.20.%d.%d", deviceNumber/250, deviceNumber%250)
			updates = append(updates, map[string]any{
				"agent_id":   run.AgentID,
				"gateway_id": run.GatewayID,
				"partition":  run.Partition,
				"device_id":  fmt.Sprintf("%s:%s", run.Partition, ip),
				"ip":         ip,
				"source":     run.Source.Type,
				"metadata":   map[string]string{"integration_type": run.Source.Type},
			})
		}

		if raw := run.Source.Credentials["raw_mac"]; raw != "" && page == 0 {
			updates[0]["mac"] = raw
			updates[0]["metadata"].(map[string]string)["mac_addresses"] = raw
		}

		if err := run.Emit(updates); err != nil {
			return total, err
		}
		total += len(updates)
	}

	if run.Source.Credentials["report_population"] == rawBoolTrue && run.ReportPopulation != nil {
		run.ReportPopulation(syncsources.PopulationStats{RawRows: total, ValidOccurrences: total})
	}

	return total, nil
}

func fakeDriverInt(creds map[string]string, key string, fallback int) int {
	raw := creds[key]
	if raw == "" {
		return fallback
	}

	parsed, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}

	return parsed
}

// newSyncTestRuntime is a sync runtime on an open edge spool, holding the sync
// page grant, with the synthetic driver registered.
func newSyncTestRuntime(t *testing.T) (*SyncRuntime, *PushLoop, *spool.Spool) {
	t.Helper()
	sp := openTestEdgeSpool(t)
	loop, runtime := syncTestRuntime(t, sp)
	runtime.drivers = fakeSyncDrivers()
	grantDiscovery(t, loop)
	return runtime, loop, sp
}

func newFakeSourceRunner(credentials map[string]string) *syncSourceRunner {
	return &syncSourceRunner{
		key: "synthetic-source",
		config: models.SourceConfig{
			Type:          fakeSyncSourceType,
			Endpoint:      "https://synthetic.example",
			SyncServiceID: "sync-source-1",
			Credentials:   credentials,
		},
	}
}

// spooledSyncDevices is every device a run spooled, in spool order.
func spooledSyncDevices(t *testing.T, sp *spool.Spool) []*edgev1.SyncDeviceRecordV1 {
	t.Helper()
	var devices []*edgev1.SyncDeviceRecordV1
	for _, page := range decodeSyncPages(t, sp) {
		devices = append(devices, page.GetDevices()...)
	}
	return devices
}

func TestRunSourceOnceSpoolsPagedDriverUpdatesAsSyncPages(t *testing.T) {
	const (
		pages          = 3
		devicesPerPage = 100
		totalDevices   = pages * devicesPerPage
	)

	runtime, _, sp := newSyncTestRuntime(t)
	runner := newFakeSourceRunner(map[string]string{
		"pages":            strconv.Itoa(pages),
		"devices_per_page": strconv.Itoa(devicesPerPage),
	})

	count, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-123")
	require.NoError(t, err)
	require.Equal(t, totalDevices, count)

	records := decodeSyncPages(t, sp)
	require.NotEmpty(t, records)
	seen := make(map[string]bool, totalDevices)
	for idx, page := range records {
		meta := page.GetSyncMeta()
		require.Equal(t, "run-123", meta.GetSyncRunId())
		require.Equal(t, int32(idx), meta.GetChunkIndex(), "records keep the run's chunk numbering")
		for _, device := range page.GetDevices() {
			require.False(t, seen[device.GetDeviceId()], "duplicate device id %q", device.GetDeviceId())
			seen[device.GetDeviceId()] = true
		}
		last := idx == len(records)-1
		require.Equal(t, last, meta.GetIsFinal(), "only the run's last record is run-final")
		if last {
			require.Equal(t, int32(totalDevices), meta.GetTotalDevices())
		}
	}
	require.Len(t, seen, totalDevices)
}

func TestRunSourceOnceSpoolsCollectionFinalAsOwnRecordWhenPopulationReported(t *testing.T) {
	const (
		pages          = 2
		devicesPerPage = 5
		totalDevices   = pages * devicesPerPage
	)

	runtime, _, sp := newSyncTestRuntime(t)
	runner := newFakeSourceRunner(map[string]string{
		"pages":             strconv.Itoa(pages),
		"devices_per_page":  strconv.Itoa(devicesPerPage),
		"report_population": rawBoolTrue,
	})

	count, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-pop")
	require.NoError(t, err)
	require.Equal(t, totalDevices, count)

	records := decodeSyncPages(t, sp)
	require.Greater(t, len(records), 1)
	for _, page := range records[:len(records)-1] {
		require.NotEmpty(t, page.GetDevices())
		require.False(t, page.GetSyncMeta().GetIsFinal(), "data records are not run-final")
	}
	final := records[len(records)-1]
	require.Empty(t, final.GetDevices())
	require.Equal(t, syncCollectionFinal, final.GetControlMarker().GetControlType())
	require.True(t, final.GetSyncMeta().GetIsFinal())
	require.Equal(t, int32(totalDevices), final.GetSyncMeta().GetTotalDevices())
}

func TestExecuteRunEndsAStalledRunAtItsDeadlineSoTheNextRunProceeds(t *testing.T) {
	runtime, _, sp := newSyncTestRuntime(t)
	runtime.runTimeout = 200 * time.Millisecond
	runner := newFakeSourceRunner(map[string]string{"stall": "true"})

	done := make(chan struct{})
	go func() {
		runtime.executeRun(context.Background(), runner, "discovery")
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("a stalled sync run never ended; the source would stop syncing")
	}

	timedOutPages := decodeSyncPages(t, sp)
	require.Len(t, timedOutPages, 1, "a timed-out run spools a terminal failure control record")
	require.Empty(t, timedOutPages[0].GetDevices())
	require.False(t, timedOutPages[0].GetSyncMeta().GetIsFinal())
	require.Contains(t, timedOutPages[0].GetControlMarker().GetControlType(), syncCollectionTimeout+":")

	// The source is free again: the next scheduled run executes and spools.
	runner.config.Credentials = map[string]string{"pages": "1"}
	runtime.executeRun(context.Background(), runner, "poll")

	require.NotEmpty(t, spooledSyncDevices(t, sp), "the run after a timed-out run spooled no devices")
}

// countingSyncDriver counts the runs that reached it.
type countingSyncDriver struct{ runs *int }

func (d countingSyncDriver) Sync(context.Context, syncsources.RunContext) (int, error) {
	*d.runs++
	return 0, nil
}

// Without the sync page grant a run would have nowhere to put its pages: it
// does not start, so the integration is read again on the next run, and the
// hold is counted. A page emitted after the grant lapses mid-run fails.
func TestSyncRunDoesNotStartWithoutTheSyncPageGrant(t *testing.T) {
	runtime, loop, sp := newSyncTestRuntime(t)
	runs := 0
	runtime.drivers = syncsources.Registry{}
	runtime.drivers.Register(fakeSyncSourceType, func() syncsources.SourceDriver {
		return countingSyncDriver{runs: &runs}
	})
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, time.Now())

	runner := newFakeSourceRunner(nil)
	runtime.executeRun(context.Background(), runner, "poll")

	require.Zero(t, runs, "a sync run started without a sync page grant")
	require.Equal(t, uint64(1), loop.server.edgeProducerDrops.grantHolds[edgeProducerSync].Load())
	require.Empty(t, spooledRecords(t, sp))

	_, err := runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{syncUpdate("src-a", "192.0.2.60")}, "run-1", 1, 0, true, nil)
	require.ErrorIs(t, err, errSyncNoGrant)
	require.Empty(t, spooledRecords(t, sp))
}

func TestSyncRunTimeoutFollowsTheScheduleWithinBounds(t *testing.T) {
	cases := []struct {
		interval time.Duration
		want     time.Duration
	}{
		{0, minSyncRunTimeout},
		{time.Minute, minSyncRunTimeout},
		{time.Hour, time.Hour},
		{24 * time.Hour, maxSyncRunTimeout},
	}
	for _, tc := range cases {
		source := models.SourceConfig{PollInterval: models.Duration(tc.interval)}
		if got := syncRunTimeout(source); got != tc.want {
			t.Fatalf("interval %s: timeout %s, want %s", tc.interval, got, tc.want)
		}
	}
}

func TestRunSourceOnceFlushesEmittedPagesWhenDriverFails(t *testing.T) {
	runtime, _, sp := newSyncTestRuntime(t)
	runner := newFakeSourceRunner(map[string]string{
		"pages":            "2",
		"devices_per_page": "2",
		"fail_after_pages": "1",
	})

	count, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-123")
	require.ErrorIs(t, err, errFakeSyncDriverFailed)
	require.Equal(t, 2, count, "the first page is flushed before the error")

	require.Len(t, spooledSyncDevices(t, sp), 2)
	pages := decodeSyncPages(t, sp)
	require.Len(t, pages, 2, "flushed partial data page followed by failure control page")
	for _, page := range pages {
		require.False(t, page.GetSyncMeta().GetIsFinal(), "a failed run is never run-final")
	}
	failurePage := pages[len(pages)-1]
	require.Empty(t, failurePage.GetDevices())
	require.Equal(t, int32(1), failurePage.GetSyncMeta().GetChunkIndex())
	require.Equal(t, int32(2), failurePage.GetSyncMeta().GetTotalDevices())
	require.Equal(t, syncCollectionFailed+":"+errFakeSyncDriverFailed.Error(),
		failurePage.GetControlMarker().GetControlType())
}

func TestRunSourceOnceSpoolsFailureControlRecordWhenDriverFailsBeforeFirstPage(t *testing.T) {
	runtime, _, sp := newSyncTestRuntime(t)
	runner := newFakeSourceRunner(map[string]string{
		"pages":            "1",
		"devices_per_page": "2",
		"fail_after_pages": "0",
	})

	count, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-zero-pages")
	require.ErrorIs(t, err, errFakeSyncDriverFailed)
	require.Zero(t, count)

	pages := decodeSyncPages(t, sp)
	require.Len(t, pages, 1)
	require.Empty(t, pages[0].GetDevices())
	require.False(t, pages[0].GetSyncMeta().GetIsFinal())
	require.Equal(t, "run-zero-pages", pages[0].GetSyncMeta().GetSyncRunId())
	require.Equal(t, int32(0), pages[0].GetSyncMeta().GetChunkIndex())
	require.Equal(t, int32(0), pages[0].GetSyncMeta().GetTotalDevices())
	require.Equal(t, syncCollectionFailed+":"+errFakeSyncDriverFailed.Error(),
		pages[0].GetControlMarker().GetControlType())
}

func TestRunSourceOnceNormalizesEmittedUpdatesForEverySource(t *testing.T) {
	runtime, _, sp := newSyncTestRuntime(t)
	runner := newFakeSourceRunner(map[string]string{
		"raw_mac": "junk,00:1A:A0:B9:40:40,001422F42A2A",
	})

	count, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-123")
	require.NoError(t, err)
	require.Equal(t, 1, count)

	devices := spooledSyncDevices(t, sp)
	require.Len(t, devices, 1)
	require.Equal(t, "00:1A:A0:B9:40:40", devices[0].GetMac(), "first valid atomic MAC")
	require.Equal(t, "001AA0B94040,001422F42A2A", devices[0].GetMetadata()["mac_addresses"],
		"validated normalized MAC list")
}

func TestRunSourceOnceRejectsUnregisteredSourceType(t *testing.T) {
	runtime, _, sp := newSyncTestRuntime(t)
	runner := &syncSourceRunner{
		key: "unknown-source",
		config: models.SourceConfig{
			Type:     "no-such-source",
			Endpoint: "https://example.invalid",
		},
	}

	_, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-123")
	require.ErrorIs(t, err, errUnsupportedSyncSourceType)
	require.Empty(t, spooledRecords(t, sp), "no updates are spooled for unsupported source types")
}

func TestIsSupportedSourceDerivesFromRegistry(t *testing.T) {
	drivers := fakeSyncDrivers()

	if !drivers.IsSupported(fakeSyncSourceType) {
		t.Fatalf("registered source type %q should be supported", fakeSyncSourceType)
	}
	if !drivers.IsSupported("  SYNTHETIC ") {
		t.Fatal("source type matching should be case-insensitive and trimmed")
	}
	if drivers.IsSupported("no-such-source") {
		t.Fatal("unregistered source type should not be supported")
	}
}

func TestParseSyncSourcesDecodesPayload(t *testing.T) {
	payload := []byte(`{
		"agent_id": "agent-a",
		"sources": {
			"corp": {
				"type": "synthetic",
				"endpoint": "https://synthetic.example",
				"sync_service_id": "sync-source-1"
			}
		}
	}`)

	sources, err := parseSyncSources(payload)
	if err != nil {
		t.Fatalf("parseSyncSources returned error: %v", err)
	}
	if len(sources) != 1 {
		t.Fatalf("source count = %d, want 1", len(sources))
	}

	source, ok := sources["corp"]
	if !ok {
		t.Fatalf("missing corp source: %#v", sources)
	}
	if source.Type != "synthetic" || source.Endpoint != "https://synthetic.example" {
		t.Fatalf("source = %#v", source)
	}
	if source.SyncServiceID != "sync-source-1" {
		t.Fatalf("sync_service_id = %q", source.SyncServiceID)
	}
}

func TestParseSyncSourcesEmptyPayload(t *testing.T) {
	for name, payload := range map[string][]byte{
		"nil":        nil,
		"empty":      {},
		"no-sources": []byte(`{"agent_id":"agent-a"}`),
	} {
		sources, err := parseSyncSources(payload)
		if err != nil {
			t.Fatalf("%s: parseSyncSources returned error: %v", name, err)
		}
		if sources != nil {
			t.Fatalf("%s: sources = %#v, want nil", name, sources)
		}
	}
}

func TestParseSyncSourcesRejectsInvalidJSON(t *testing.T) {
	if _, err := parseSyncSources([]byte(`{not json`)); err == nil {
		t.Fatal("expected decode error")
	}
}

func TestScheduledSyncRunPrefersDiscoveryInterval(t *testing.T) {
	interval, kind, ok := scheduledSyncRun(models.SourceConfig{
		PollInterval:      models.Duration(5 * time.Minute),
		DiscoveryInterval: models.Duration(time.Hour),
	})

	if !ok {
		t.Fatal("expected schedule")
	}
	if interval != time.Hour {
		t.Fatalf("interval = %v, want 1h", interval)
	}
	if kind != "discovery" {
		t.Fatalf("kind = %q, want discovery", kind)
	}
}

func TestScheduledSyncRunFallsBackToPollInterval(t *testing.T) {
	interval, kind, ok := scheduledSyncRun(models.SourceConfig{
		PollInterval: models.Duration(5 * time.Minute),
	})

	if !ok {
		t.Fatal("expected schedule")
	}
	if interval != 5*time.Minute {
		t.Fatalf("interval = %v, want 5m", interval)
	}
	if kind != "poll" {
		t.Fatalf("kind = %q, want poll", kind)
	}
}

func TestClaimInitialSyncRunThrottlesRecentSameConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync-runtime-runs.json")
	now := time.Date(2026, 5, 13, 3, 0, 0, 0, time.UTC)

	claimed, err := claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now)
	if err != nil {
		t.Fatalf("first claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("first claim should run")
	}

	claimed, err = claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now.Add(5*time.Minute))
	if err != nil {
		t.Fatalf("second claim returned error: %v", err)
	}
	if claimed {
		t.Fatal("second claim should be throttled")
	}

	claimed, err = claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now.Add(time.Hour))
	if err != nil {
		t.Fatalf("third claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("claim after interval should run")
	}
}

func TestClaimInitialSyncRunAllowsChangedConfigHash(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync-runtime-runs.json")
	now := time.Date(2026, 5, 13, 3, 0, 0, 0, time.UTC)

	claimed, err := claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now)
	if err != nil {
		t.Fatalf("first claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("first claim should run")
	}

	claimed, err = claimInitialSyncRun(path, "source-a:hash-b", time.Hour, now.Add(5*time.Minute))
	if err != nil {
		t.Fatalf("changed hash claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("changed config hash should run immediately")
	}
}

func TestSyncFailureControlValueTruncatesUpstreamErrorToMarshalableUTF8(t *testing.T) {
	value := syncFailureControlValue(errLongMultibyteUpstream)

	require.True(t, utf8.ValidString(value))
	require.Equal(t, syncCollectionFailed+":"+strings.Repeat("a", syncControlErrorMaxBytes-1), value)

	_, err := proto.Marshal(&edgev1.SyncControlMarkerV1{ControlType: value})
	require.NoError(t, err)
}

func TestSyncFailureControlValueDropsInvalidUTF8FromShortUpstreamError(t *testing.T) {
	value := syncFailureControlValue(errShortInvalidUTF8Upstream)

	require.Equal(t, syncCollectionFailed+":502 Bad Gateway: body", value)

	_, err := proto.Marshal(&edgev1.SyncControlMarkerV1{ControlType: value})
	require.NoError(t, err)
}
