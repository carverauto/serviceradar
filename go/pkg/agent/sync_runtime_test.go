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
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// fakeSyncSourceType is an integration-neutral source type registered only in
// tests. It drives the generic runtime pipeline (registry lookup, update
// normalization, chunking, gateway streaming) without referencing any real
// integration.
const fakeSyncSourceType = "synthetic"

var (
	errFakeSyncGatewayEmptyStream  = errors.New("empty stream")
	errFakeSyncGatewayInvalidChunk = errors.New("invalid stream chunk")
	errFakeSyncGatewayMissingFinal = errors.New("stream ended without final chunk")
	errFakeSyncDriverFailed        = errors.New("fake sync driver failed")
)

//nolint:gochecknoglobals // Tests register a synthetic driver once per process.
var registerFakeSyncDriverOnce sync.Once

func registerFakeSyncDriver() {
	registerFakeSyncDriverOnce.Do(func() {
		syncsources.Register(fakeSyncSourceType, func() syncsources.SourceDriver {
			return &fakeSyncDriver{}
		})
	})
}

// fakeSyncDriver emits synthetic device updates. Its behavior is configured
// through source credentials:
//
//	pages:            number of pages to emit (default 1)
//	devices_per_page: updates emitted per page (default 1)
//	fail_after_pages: fail after emitting this many pages (unset: never)
//	raw_mac:          raw MAC value attached to the first update of page 0
type fakeSyncDriver struct{}

func (*fakeSyncDriver) Sync(_ context.Context, run syncsources.RunContext) (int, error) {
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

func newSyncTestRuntime(gateway *fakeSyncGateway) *SyncRuntime {
	return &SyncRuntime{
		server:  &Server{config: &ServerConfig{AgentID: "agent-a", Partition: "partition-a"}},
		gateway: gateway,
		logger:  createTestLogger(),
	}
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

func TestRunSourceOnceStreamsPagedDriverUpdatesAsGatewayResults(t *testing.T) {
	registerFakeSyncDriver()

	const (
		pages          = 3
		devicesPerPage = 100
		totalDevices   = pages * devicesPerPage
	)

	gateway := &fakeSyncGateway{}
	runtime := newSyncTestRuntime(gateway)
	runner := newFakeSourceRunner(map[string]string{
		"pages":            strconv.Itoa(pages),
		"devices_per_page": strconv.Itoa(devicesPerPage),
	})

	count, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-123")
	if err != nil {
		t.Fatalf("runSourceOnce returned error: %v", err)
	}
	if count != totalDevices {
		t.Fatalf("count = %d, want %d", count, totalDevices)
	}

	streams := gateway.streamsSnapshot()
	if len(streams) != pages {
		t.Fatalf("stream count = %d, want %d pages", len(streams), pages)
	}

	seen := make(map[string]bool, totalDevices)
	for streamIdx, stream := range streams {
		if len(stream) == 0 {
			t.Fatalf("stream %d was empty", streamIdx)
		}
		for chunkIdx, chunk := range stream {
			assertGatewayResultsChunk(t, streamIdx, chunkIdx, len(stream), chunk)
			for _, deviceID := range decodedSyncChunkDeviceIDs(t, []*proto.GatewayStatusChunk{chunk}) {
				if seen[deviceID] {
					t.Fatalf("duplicate device id %q", deviceID)
				}
				seen[deviceID] = true
			}
		}
		lastChunk := stream[len(stream)-1]
		if !lastChunk.IsFinal {
			t.Fatalf("stream %d last chunk is not final", streamIdx)
		}
		if streamIdx == len(streams)-1 {
			assertSyncChunkRunFinal(t, lastChunk, true)
			assertSyncChunkRunTotal(t, lastChunk, totalDevices)
		} else {
			assertSyncChunkRunFinal(t, lastChunk, false)
		}
	}

	if len(seen) != totalDevices {
		t.Fatalf("streamed device count = %d, want %d", len(seen), totalDevices)
	}
}

func TestRunSourceOnceFlushesEmittedPagesWhenDriverFails(t *testing.T) {
	registerFakeSyncDriver()

	gateway := &fakeSyncGateway{}
	runtime := newSyncTestRuntime(gateway)
	runner := newFakeSourceRunner(map[string]string{
		"pages":            "2",
		"devices_per_page": "2",
		"fail_after_pages": "1",
	})

	count, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-123")
	if !errors.Is(err, errFakeSyncDriverFailed) {
		t.Fatalf("error = %v, want driver failure", err)
	}
	if count != 2 {
		t.Fatalf("count = %d, want flushed first page count", count)
	}

	streams := gateway.streamsSnapshot()
	if len(streams) != 1 {
		t.Fatalf("stream count = %d, want first page flushed before error", len(streams))
	}

	gotDevices := decodedSyncChunkDeviceIDs(t, gateway.chunks())
	if len(gotDevices) != 2 {
		t.Fatalf("streamed device count = %d, want 2: %v", len(gotDevices), gotDevices)
	}

	lastStream := streams[len(streams)-1]
	assertSyncChunkRunFinal(t, lastStream[len(lastStream)-1], false)
}

func TestRunSourceOnceNormalizesEmittedUpdatesForEverySource(t *testing.T) {
	registerFakeSyncDriver()

	gateway := &fakeSyncGateway{}
	runtime := newSyncTestRuntime(gateway)
	runner := newFakeSourceRunner(map[string]string{
		"raw_mac": "junk,00:1A:A0:B9:40:40,001422F42A2A",
	})

	count, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-123")
	if err != nil {
		t.Fatalf("runSourceOnce returned error: %v", err)
	}
	if count != 1 {
		t.Fatalf("count = %d, want 1", count)
	}

	updates := decodedSyncChunkUpdates(t, gateway.chunks())
	if len(updates) != 1 {
		t.Fatalf("update count = %d, want 1", len(updates))
	}

	update := updates[0]
	if update["mac"] != "00:1A:A0:B9:40:40" {
		t.Fatalf("update[mac] = %q, want first valid atomic MAC", update["mac"])
	}

	metadata, ok := update["metadata"].(map[string]interface{})
	if !ok {
		t.Fatalf("metadata has type %T, want map", update["metadata"])
	}
	if got := metadata["mac_addresses"]; got != "001AA0B94040,001422F42A2A" {
		t.Fatalf("metadata[mac_addresses] = %q, want validated normalized MAC list", got)
	}
}

func TestRunSourceOnceRejectsUnregisteredSourceType(t *testing.T) {
	gateway := &fakeSyncGateway{}
	runtime := newSyncTestRuntime(gateway)
	runner := &syncSourceRunner{
		key: "unknown-source",
		config: models.SourceConfig{
			Type:     "no-such-source",
			Endpoint: "https://example.invalid",
		},
	}

	_, err := runtime.runSourceOnce(context.Background(), runner, "discovery", "run-123")
	if !errors.Is(err, errUnsupportedSyncSourceType) {
		t.Fatalf("error = %v, want errUnsupportedSyncSourceType", err)
	}
	if len(gateway.chunks()) != 0 {
		t.Fatal("no updates should be streamed for unsupported source types")
	}
}

func TestIsSupportedSourceDerivesFromRegistry(t *testing.T) {
	registerFakeSyncDriver()

	if !isSupportedSource(fakeSyncSourceType) {
		t.Fatalf("registered source type %q should be supported", fakeSyncSourceType)
	}
	if !isSupportedSource("  SYNTHETIC ") {
		t.Fatal("source type matching should be case-insensitive and trimmed")
	}
	if isSupportedSource("no-such-source") {
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

type fakeSyncGateway struct {
	mu      sync.Mutex
	streams [][]*proto.GatewayStatusChunk
}

func (f *fakeSyncGateway) StreamStatus(
	_ context.Context,
	chunks []*proto.GatewayStatusChunk,
) (*proto.GatewayStatusResponse, error) {
	if len(chunks) == 0 {
		return nil, errFakeSyncGatewayEmptyStream
	}
	for i, chunk := range chunks {
		if chunk == nil {
			return nil, fmt.Errorf("nil chunk %d: %w", i, errFakeSyncGatewayInvalidChunk)
		}
		if chunk.ChunkIndex != int32(i) {
			return nil, fmt.Errorf("chunk index %d, want %d: %w", chunk.ChunkIndex, i, errFakeSyncGatewayInvalidChunk)
		}
		if chunk.TotalChunks != int32(len(chunks)) {
			return nil, fmt.Errorf(
				"total chunks %d, want %d: %w",
				chunk.TotalChunks,
				len(chunks),
				errFakeSyncGatewayInvalidChunk,
			)
		}
	}
	if !chunks[len(chunks)-1].IsFinal {
		return nil, errFakeSyncGatewayMissingFinal
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	copied := append([]*proto.GatewayStatusChunk(nil), chunks...)
	f.streams = append(f.streams, copied)
	return &proto.GatewayStatusResponse{Received: true}, nil
}

func (*fakeSyncGateway) GetGatewayID() string {
	return "gateway-a"
}

func (f *fakeSyncGateway) chunks() []*proto.GatewayStatusChunk {
	f.mu.Lock()
	defer f.mu.Unlock()
	var chunks []*proto.GatewayStatusChunk
	for _, stream := range f.streams {
		chunks = append(chunks, stream...)
	}
	return chunks
}

func (f *fakeSyncGateway) streamsSnapshot() [][]*proto.GatewayStatusChunk {
	f.mu.Lock()
	defer f.mu.Unlock()

	streams := make([][]*proto.GatewayStatusChunk, 0, len(f.streams))
	for _, stream := range f.streams {
		streams = append(streams, append([]*proto.GatewayStatusChunk(nil), stream...))
	}

	return streams
}

func assertGatewayResultsChunk(
	t *testing.T,
	streamIdx int,
	chunkIdx int,
	streamLen int,
	chunk *proto.GatewayStatusChunk,
) {
	t.Helper()

	if chunk.AgentId != "agent-a" {
		t.Fatalf("stream %d chunk %d agent_id = %q", streamIdx, chunkIdx, chunk.AgentId)
	}
	if chunk.GatewayId != "gateway-a" {
		t.Fatalf("stream %d chunk %d gateway_id = %q", streamIdx, chunkIdx, chunk.GatewayId)
	}
	if chunk.Partition != "partition-a" {
		t.Fatalf("stream %d chunk %d partition = %q", streamIdx, chunkIdx, chunk.Partition)
	}
	if chunk.TotalChunks <= 0 {
		t.Fatalf("stream %d chunk %d total_chunks = %d", streamIdx, chunkIdx, chunk.TotalChunks)
	}
	if chunk.ChunkIndex != int32(chunkIdx) {
		t.Fatalf("stream %d chunk %d chunk_index = %d", streamIdx, chunkIdx, chunk.ChunkIndex)
	}
	if int(chunk.TotalChunks) != streamLen {
		t.Fatalf("stream %d chunk %d has inconsistent total_chunks = %d", streamIdx, chunkIdx, chunk.TotalChunks)
	}
	if len(chunk.Services) != 1 {
		t.Fatalf("stream %d chunk %d service count = %d, want 1", streamIdx, chunkIdx, len(chunk.Services))
	}

	service := chunk.Services[0]
	if service.ServiceName != syncServiceName {
		t.Fatalf("stream %d chunk %d service_name = %q", streamIdx, chunkIdx, service.ServiceName)
	}
	if service.ServiceType != syncServiceType {
		t.Fatalf("stream %d chunk %d service_type = %q", streamIdx, chunkIdx, service.ServiceType)
	}
	if service.Source != "results" {
		t.Fatalf("stream %d chunk %d source = %q", streamIdx, chunkIdx, service.Source)
	}
	if service.AgentId != chunk.AgentId {
		t.Fatalf("stream %d chunk %d service agent_id = %q", streamIdx, chunkIdx, service.AgentId)
	}
	if service.GatewayId != chunk.GatewayId {
		t.Fatalf("stream %d chunk %d service gateway_id = %q", streamIdx, chunkIdx, service.GatewayId)
	}
	if len(service.Message) == 0 {
		t.Fatalf("stream %d chunk %d service message is empty", streamIdx, chunkIdx)
	}
}

func decodedSyncChunkUpdates(t *testing.T, chunks []*proto.GatewayStatusChunk) []map[string]interface{} {
	t.Helper()
	var all []map[string]interface{}
	for i, chunk := range chunks {
		for j, service := range chunk.Services {
			var updates []map[string]interface{}
			if err := json.Unmarshal(service.Message, &updates); err != nil {
				t.Fatalf("decode chunk %d service %d: %v", i, j, err)
			}
			all = append(all, updates...)
		}
	}
	return all
}

func decodedSyncChunkDeviceIDs(t *testing.T, chunks []*proto.GatewayStatusChunk) []string {
	t.Helper()
	updates := decodedSyncChunkUpdates(t, chunks)
	deviceIDs := make([]string, 0, len(updates))
	for _, update := range updates {
		deviceID, _ := update["device_id"].(string)
		if deviceID == "" {
			t.Fatalf("missing device_id in update: %#v", update)
		}
		deviceIDs = append(deviceIDs, deviceID)
	}
	return deviceIDs
}

func assertSyncChunkRunTotal(t *testing.T, chunk *proto.GatewayStatusChunk, want int) {
	t.Helper()
	meta := syncMetaFromStatusChunk(t, chunk)

	got, ok := meta["total_devices"].(float64)
	if !ok {
		t.Fatalf("sync_meta total_devices = %#v", meta["total_devices"])
	}
	if int(got) != want {
		t.Fatalf("sync_meta total_devices = %d, want %d", int(got), want)
	}
}

func assertSyncChunkRunFinal(t *testing.T, chunk *proto.GatewayStatusChunk, want bool) {
	t.Helper()
	meta := syncMetaFromStatusChunk(t, chunk)

	got, ok := meta["is_final"].(bool)
	if !ok {
		t.Fatalf("sync_meta is_final = %#v", meta["is_final"])
	}
	if got != want {
		t.Fatalf("sync_meta is_final = %v, want %v", got, want)
	}
}

func syncMetaFromStatusChunk(t *testing.T, chunk *proto.GatewayStatusChunk) map[string]interface{} {
	t.Helper()
	if len(chunk.Services) == 0 {
		t.Fatal("chunk has no services")
	}

	var updates []map[string]interface{}
	if err := json.Unmarshal(chunk.Services[0].Message, &updates); err != nil {
		t.Fatalf("decode chunk: %v", err)
	}
	if len(updates) == 0 {
		t.Fatal("chunk has no updates")
	}

	meta, ok := updates[len(updates)-1]["sync_meta"].(map[string]interface{})
	if !ok {
		t.Fatalf("update missing sync_meta: %#v", updates[len(updates)-1])
	}
	return meta
}

func TestBuildSyncResultsChunksPublishesBoundedPopulationOnlyOnRunFinal(t *testing.T) {
	examples := make([]string, 120)
	for i := range examples {
		examples[i] = strconv.Itoa(i + 1)
	}
	population := &syncsources.PopulationStats{
		RawRows: 130, ExcludedRows: 2, InvalidRows: 3, ValidOccurrences: 125,
		DistinctSourceIDs: 120, DuplicateOccurrences: 5,
		DuplicateSourceIDExamples: examples,
		InvalidRowExamples:        examples,
		ConflictingDuplicateIDs:   examples,
	}
	source := models.SourceConfig{SyncServiceID: "source-a"}
	update := func() []map[string]interface{} {
		return []map[string]interface{}{{"device_id": "default:10.0.0.1"}}
	}

	nonfinal, err := buildSyncResultsChunks(update(), source, "run-a", 1, 0, false, population)
	if err != nil {
		t.Fatalf("build non-final chunks: %v", err)
	}
	if _, exists := syncMetaFromResultsChunk(t, nonfinal[0])["population"]; exists {
		t.Fatal("non-final chunk unexpectedly published population accounting")
	}

	final, err := buildSyncResultsChunks(update(), source, "run-a", 1, 0, true, population)
	if err != nil {
		t.Fatalf("build final chunks: %v", err)
	}
	got, ok := syncMetaFromResultsChunk(t, final[len(final)-1])["population"].(map[string]interface{})
	if !ok {
		t.Fatalf("final chunk population = %#v", got)
	}
	if int(got["conflicting_duplicate_ids"].(float64)) != 120 {
		t.Fatalf("conflicting duplicate count = %#v, want 120", got["conflicting_duplicate_ids"])
	}
	if int(got["excluded_rows"].(float64)) != 2 {
		t.Fatalf("excluded row count = %#v, want 2", got["excluded_rows"])
	}
	if gotExamples, _ := got["conflicting_duplicate_examples"].([]interface{}); len(gotExamples) != 100 {
		t.Fatalf("conflicting duplicate examples = %d, want bounded 100", len(gotExamples))
	}
	if gotExamples, _ := got["duplicate_source_id_examples"].([]interface{}); len(gotExamples) != 100 {
		t.Fatalf("duplicate source-ID examples = %d, want bounded 100", len(gotExamples))
	}
	if gotExamples, _ := got["invalid_row_examples"].([]interface{}); len(gotExamples) != 100 {
		t.Fatalf("invalid row examples = %d, want bounded 100", len(gotExamples))
	}
}

func TestBuildSyncResultsChunksPublishesZeroDeviceCollectionFinal(t *testing.T) {
	population := &syncsources.PopulationStats{
		RawRows: 2, ExcludedRows: 2,
	}
	control := []map[string]interface{}{{
		syncControlKey: syncCollectionFinal,
		"timestamp":    "2026-09-01T08:00:00Z",
	}}

	chunks, err := buildSyncResultsChunks(
		control,
		models.SourceConfig{SyncServiceID: "source-a"},
		"run-empty",
		0,
		0,
		true,
		population,
	)
	if err != nil {
		t.Fatalf("build empty collection final: %v", err)
	}
	if len(chunks) != 1 {
		t.Fatalf("chunks = %d, want 1", len(chunks))
	}

	meta := syncMetaFromResultsChunk(t, chunks[0])
	if got := int(meta["total_devices"].(float64)); got != 0 {
		t.Fatalf("total_devices = %d, want 0", got)
	}
	if got, _ := meta["is_final"].(bool); !got {
		t.Fatal("empty collection marker is not final")
	}
	gotPopulation, _ := meta["population"].(map[string]interface{})
	if got := int(gotPopulation["excluded_rows"].(float64)); got != 2 {
		t.Fatalf("excluded_rows = %d, want 2", got)
	}
}

func syncMetaFromResultsChunk(t *testing.T, chunk *proto.ResultsChunk) map[string]interface{} {
	t.Helper()
	var updates []map[string]interface{}
	if err := json.Unmarshal(chunk.Data, &updates); err != nil {
		t.Fatalf("decode results chunk: %v", err)
	}
	meta, ok := updates[len(updates)-1][syncMetaKey].(map[string]interface{})
	if !ok {
		t.Fatalf("update missing sync_meta: %#v", updates[len(updates)-1])
	}
	return meta
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
