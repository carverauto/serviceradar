package agent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	syncServiceType            = "sync"
	syncServiceName            = "sync"
	syncMetaKey                = "sync_meta"
	syncControlKey             = "_sync_control"
	syncCollectionFinal        = "collection_final"
	syncPopulationExampleLimit = 100
)

var (
	errSyncRuntimeNoContext      = errors.New("sync runtime requires context")
	errUnsupportedSyncSourceType = errors.New("unsupported sync source type")
)

// SyncRuntime executes integration sources delivered via GetConfig. It is
// integration-agnostic: concrete source drivers are looked up in the
// syncsources registry, and every update they emit flows through the same
// normalization, chunking, and gateway streaming pipeline.
type SyncRuntime struct {
	server  *Server
	gateway syncGateway
	logger  logger.Logger

	mu      sync.Mutex
	stateMu sync.Mutex
	ctx     context.Context
	sources map[string]*syncSourceRunner
}

type syncGateway interface {
	StreamStatus(context.Context, []*proto.GatewayStatusChunk) (*proto.GatewayStatusResponse, error)
	GetGatewayID() string
}

type syncSourceRunner struct {
	key    string
	hash   string
	config models.SourceConfig
	cancel context.CancelFunc

	mu       sync.Mutex
	inflight bool
}

type syncConfigPayload struct {
	AgentID string                         `json:"agent_id"`
	Sources map[string]models.SourceConfig `json:"sources"`
}

type syncRuntimeRunState struct {
	Runs map[string]time.Time `json:"runs"`
}

// NewSyncRuntime builds the integration sync runtime for an agent.
func NewSyncRuntime(server *Server, gateway *agentgateway.GatewayClient, log logger.Logger) *SyncRuntime {
	return &SyncRuntime{
		server:  server,
		gateway: gateway,
		logger:  log,
		sources: make(map[string]*syncSourceRunner),
	}
}

// SetContext sets the base context for sync runners (called from PushLoop.Start).
func (r *SyncRuntime) SetContext(ctx context.Context) {
	r.mu.Lock()
	r.ctx = ctx
	r.mu.Unlock()
}

// ApplyConfig parses sync sources from the gateway payload and starts/stops runners.
func (r *SyncRuntime) ApplyConfig(configJSON []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.ctx == nil {
		r.logger.Warn().Err(errSyncRuntimeNoContext).Msg("Skipping sync runtime config")
		return
	}

	if !syncRuntimeEnabled(r.server.config) {
		r.stopAllLocked()
		return
	}

	sources, err := parseSyncSources(configJSON)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to parse sync sources from config")
		return
	}

	if len(sources) == 0 {
		r.stopAllLocked()
		return
	}

	// Stop removed sources.
	for key, runner := range r.sources {
		if _, ok := sources[key]; !ok {
			runner.cancel()
			delete(r.sources, key)
		}
	}

	for key, source := range sources {
		if !isSupportedSource(source.Type) {
			r.logger.Warn().Str("source", key).Str("type", source.Type).
				Msg("Skipping unsupported sync source type")
			continue
		}

		if strings.TrimSpace(source.Endpoint) == "" {
			r.logger.Warn().Str("source", key).Msg("Skipping sync source without endpoint")
			continue
		}

		hash := syncSourceHash(source)
		if existing, ok := r.sources[key]; ok {
			if existing.hash == hash {
				continue
			}
			existing.cancel()
			delete(r.sources, key)
		}

		r.sources[key] = r.startSourceLocked(key, source, hash)
	}
}

func (r *SyncRuntime) stopAllLocked() {
	for key, runner := range r.sources {
		runner.cancel()
		delete(r.sources, key)
	}
}

func (r *SyncRuntime) startSourceLocked(key string, source models.SourceConfig, hash string) *syncSourceRunner {
	ctx, cancel := context.WithCancel(r.ctx)
	runner := &syncSourceRunner{
		key:    key,
		hash:   hash,
		config: source,
		cancel: cancel,
	}

	go r.runSource(ctx, runner)
	return runner
}

func (r *SyncRuntime) runSource(ctx context.Context, runner *syncSourceRunner) {
	interval, runKind, ok := scheduledSyncRun(runner.config)
	if !ok {
		r.logger.Warn().Str("source", runner.key).Msg("Sync source has no intervals configured")
		return
	}

	// Run an initial discovery immediately.
	if r.claimInitialRun(runner, interval) {
		r.executeRun(ctx, runner, "discovery")
	} else {
		r.logger.Info().
			Str("source", runner.key).
			Dur("interval", interval).
			Msg("Skipping initial sync run; recent run marker exists")
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.executeRun(ctx, runner, runKind)
		}
	}
}

func scheduledSyncRun(source models.SourceConfig) (time.Duration, string, bool) {
	discoveryInterval := time.Duration(source.DiscoveryInterval)
	if discoveryInterval > 0 {
		return discoveryInterval, "discovery", true
	}

	pollInterval := time.Duration(source.PollInterval)
	if pollInterval > 0 {
		return pollInterval, "poll", true
	}

	return 0, "", false
}

func (r *SyncRuntime) claimInitialRun(runner *syncSourceRunner, interval time.Duration) bool {
	r.stateMu.Lock()
	defer r.stateMu.Unlock()

	claimed, err := claimInitialSyncRun(syncRuntimeStateFile(), initialSyncRunKey(runner), interval, time.Now())
	if err != nil {
		r.logger.Warn().Err(err).Str("source", runner.key).Msg("Failed to update sync runtime state")
		return true
	}

	return claimed
}

func initialSyncRunKey(runner *syncSourceRunner) string {
	sourceID := runner.config.SyncServiceID
	if sourceID == "" {
		sourceID = runner.key
	}

	return sourceID + ":" + runner.hash
}

func syncRuntimeStateFile() string {
	if override := strings.TrimSpace(os.Getenv("SERVICERADAR_SYNC_RUNTIME_STATE_PATH")); override != "" {
		return override
	}

	return filepath.Join(defaultStateDir(), "cache", "sync-runtime-runs.json")
}

func claimInitialSyncRun(path string, key string, interval time.Duration, now time.Time) (bool, error) {
	if key == "" || interval <= 0 {
		return true, nil
	}

	state := syncRuntimeRunState{Runs: make(map[string]time.Time)}
	if data, err := os.ReadFile(path); err == nil && len(data) > 0 {
		if err := json.Unmarshal(data, &state); err != nil {
			state = syncRuntimeRunState{Runs: make(map[string]time.Time)}
		}
	}
	if state.Runs == nil {
		state.Runs = make(map[string]time.Time)
	}

	if lastRun, ok := state.Runs[key]; ok && now.Sub(lastRun) < interval {
		return false, nil
	}

	state.Runs[key] = now.UTC()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return true, err
	}

	data, err := json.Marshal(state)
	if err != nil {
		return true, err
	}

	if err := os.WriteFile(path, data, 0644); err != nil {
		return true, err
	}

	return true, nil
}

func (r *SyncRuntime) executeRun(ctx context.Context, runner *syncSourceRunner, runKind string) {
	if !runner.tryStart() {
		r.logger.Debug().Str("source", runner.key).Msg("Sync run skipped (in progress)")
		return
	}
	defer runner.finish()

	runID := uuid.NewString()

	start := time.Now()
	count, err := r.runSourceOnce(ctx, runner, runKind, runID)
	duration := time.Since(start)

	logEvent := r.logger.Info()
	if err != nil {
		logEvent = r.logger.Error().Err(err)
	}

	logEvent.Str("source", runner.key).
		Str("type", runner.config.Type).
		Str("run_id", runID).
		Str("kind", runKind).
		Int("device_count", count).
		Dur("duration", duration).
		Msg("Sync run completed")
}

// runSourceOnce executes a single sync run by resolving the source driver
// from the registry and streaming everything it emits to the gateway.
func (r *SyncRuntime) runSourceOnce(
	ctx context.Context,
	runner *syncSourceRunner,
	_ string,
	runID string,
) (int, error) {
	sourceType := syncsources.NormalizeType(runner.config.Type)
	ctor, ok := syncsources.Lookup(sourceType)
	if !ok {
		return 0, fmt.Errorf("%w: %s", errUnsupportedSyncSourceType, sourceType)
	}

	identity := r.runIdentity(runner)
	emitter := &syncRunEmitter{
		runtime: r,
		runner:  runner,
		runID:   runID,
	}

	driver := ctor()
	_, err := driver.Sync(ctx, syncsources.RunContext{
		RunID:     runID,
		SourceKey: runner.key,
		AgentID:   identity.agentID,
		GatewayID: identity.gatewayID,
		Partition: identity.partition,
		Source:    runner.config,
		Logger:    r.logger,
		Emit: func(updates []map[string]any) error {
			return emitter.emit(ctx, updates)
		},
		ReportPopulation: emitter.reportPopulation,
	})
	if err != nil {
		// Flush any buffered page so already-fetched devices still reach the
		// gateway; the run-final marker is withheld on partial runs.
		if flushErr := emitter.flush(ctx, false); flushErr != nil {
			r.logger.Warn().Err(flushErr).
				Str("source", runner.key).
				Str("run_id", runID).
				Msg("Failed to flush buffered sync updates after run error")
		}

		return emitter.sent, err
	}

	if err := emitter.flush(ctx, true); err != nil {
		return emitter.sent, err
	}

	return emitter.sent, nil
}

type syncRunIdentity struct {
	agentID   string
	gatewayID string
	partition string
}

// runIdentity resolves the agent/gateway/partition identity for a sync run,
// preferring per-source overrides over the agent's own configuration.
func (r *SyncRuntime) runIdentity(runner *syncSourceRunner) syncRunIdentity {
	r.server.mu.RLock()
	agentID := r.server.config.AgentID
	partition := r.server.config.Partition
	r.server.mu.RUnlock()

	if runner.config.AgentID != "" {
		agentID = runner.config.AgentID
	}
	gatewayID := agentID
	if runner.config.GatewayID != "" {
		gatewayID = runner.config.GatewayID
	}
	if runner.config.Partition != "" {
		partition = runner.config.Partition
	}
	if partition == "" {
		partition = defaultPartition
	}

	return syncRunIdentity{
		agentID:   agentID,
		gatewayID: gatewayID,
		partition: partition,
	}
}

// syncRunEmitter streams driver-emitted update batches to the gateway. It
// buffers one batch so the final batch of a successful run can be marked as
// the run-final page, and applies the generic update normalization to every
// update regardless of the source integration.
type syncRunEmitter struct {
	runtime *SyncRuntime
	runner  *syncSourceRunner
	runID   string

	pending    []map[string]interface{}
	sent       int
	chunkIndex int
	population *syncsources.PopulationStats
}

func (e *syncRunEmitter) reportPopulation(stats syncsources.PopulationStats) {
	copyStats := stats
	copyStats.DuplicateSourceIDExamples = boundedPopulationExamples(stats.DuplicateSourceIDExamples)
	copyStats.InvalidRowExamples = boundedPopulationExamples(stats.InvalidRowExamples)
	copyStats.ConflictingDuplicateIDs = append([]string(nil), stats.ConflictingDuplicateIDs...)
	e.population = &copyStats
}

func (e *syncRunEmitter) emit(ctx context.Context, updates []map[string]interface{}) error {
	batch := make([]map[string]interface{}, 0, len(updates))
	for _, update := range updates {
		if update == nil {
			continue
		}
		syncsources.NormalizeUpdate(update)
		batch = append(batch, update)
	}
	if len(batch) == 0 {
		return nil
	}

	if err := e.flush(ctx, false); err != nil {
		return err
	}
	e.pending = batch

	return nil
}

func (e *syncRunEmitter) flush(ctx context.Context, runFinal bool) error {
	if len(e.pending) == 0 {
		if runFinal && e.population != nil {
			control := map[string]interface{}{
				syncControlKey: syncCollectionFinal,
				"timestamp":    time.Now().UTC().Truncate(time.Second).Format(time.RFC3339),
			}

			sentChunks, err := e.runtime.sendSyncUpdates(
				ctx,
				e.runner,
				[]map[string]interface{}{control},
				e.runID,
				e.sent,
				e.chunkIndex,
				true,
				e.population,
			)
			if err != nil {
				return err
			}
			e.chunkIndex += sentChunks
		}
		return nil
	}

	pending := e.pending
	e.pending = nil

	sentChunks, err := e.runtime.sendSyncUpdates(
		ctx,
		e.runner,
		pending,
		e.runID,
		e.sent+len(pending),
		e.chunkIndex,
		runFinal,
		e.population,
	)
	if err != nil {
		return err
	}

	e.chunkIndex += sentChunks
	e.sent += len(pending)

	return nil
}

func (r *SyncRuntime) sendSyncUpdates(
	ctx context.Context,
	runner *syncSourceRunner,
	updates []map[string]interface{},
	runID string,
	runTotalDevices int,
	baseChunkIndex int,
	runFinalPage bool,
	population *syncsources.PopulationStats,
) (int, error) {
	chunks, err := buildSyncResultsChunks(
		updates,
		runner.config,
		runID,
		runTotalDevices,
		baseChunkIndex,
		runFinalPage,
		population,
	)
	if err != nil {
		return 0, err
	}
	if len(chunks) == 0 {
		return 0, nil
	}

	statusChunks := r.buildResultsStatusChunks(chunks, syncServiceName, syncServiceType)
	if len(statusChunks) == 0 {
		return 0, nil
	}
	markStatusStreamFinal(statusChunks)

	_, err = r.gateway.StreamStatus(ctx, statusChunks)
	return len(chunks), err
}

func (r *SyncRuntime) buildResultsStatusChunks(
	chunks []*proto.ResultsChunk,
	serviceName string,
	serviceType string,
) []*proto.GatewayStatusChunk {
	r.server.mu.RLock()
	agentID := r.server.config.AgentID
	partition := r.server.config.Partition
	r.server.mu.RUnlock()
	gatewayID := r.gateway.GetGatewayID()
	return buildResultsStatusChunksForAgent(chunks, serviceName, serviceType, agentID, partition, gatewayID)
}

func markStatusStreamFinal(chunks []*proto.GatewayStatusChunk) {
	totalChunks := int32(len(chunks))
	for i, chunk := range chunks {
		if chunk == nil {
			continue
		}
		chunk.ChunkIndex = int32(i)
		chunk.TotalChunks = totalChunks
		chunk.IsFinal = int32(i) == totalChunks-1
	}
}

func (r *syncSourceRunner) tryStart() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.inflight {
		return false
	}
	r.inflight = true
	return true
}

func (r *syncSourceRunner) finish() {
	r.mu.Lock()
	r.inflight = false
	r.mu.Unlock()
}

func syncRuntimeEnabled(cfg *ServerConfig) bool {
	if cfg == nil {
		return false
	}
	if cfg.SyncRuntimeEnabled == nil {
		return true
	}
	return *cfg.SyncRuntimeEnabled
}

func parseSyncSources(configJSON []byte) (map[string]models.SourceConfig, error) {
	if len(configJSON) == 0 {
		return nil, nil
	}

	var payload syncConfigPayload
	if err := json.Unmarshal(configJSON, &payload); err != nil {
		return nil, fmt.Errorf("decode sync payload: %w", err)
	}

	if len(payload.Sources) == 0 {
		return nil, nil
	}

	return payload.Sources, nil
}

func syncSourceHash(source models.SourceConfig) string {
	data, err := json.Marshal(source)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:8])
}

// isSupportedSource reports whether a driver is registered for the source
// type. Supported integrations are defined solely by the syncsources
// registry; the runtime has no knowledge of individual integrations.
func isSupportedSource(sourceType string) bool {
	return syncsources.IsSupported(sourceType)
}

type syncChunkMeta struct {
	syncServiceID  string
	runID          string
	totalDevices   int
	baseChunkIndex int
	runFinalPage   bool
	population     *syncsources.PopulationStats
}

func buildSyncResultsChunks(
	updates []map[string]interface{},
	source models.SourceConfig,
	runID string,
	runTotalDevices int,
	baseChunkIndex int,
	runFinalPage bool,
	population ...*syncsources.PopulationStats,
) ([]*proto.ResultsChunk, error) {
	if len(updates) == 0 {
		return nil, nil
	}
	deviceUpdateCount := 0
	for _, update := range updates {
		if update != nil && update[syncControlKey] != syncCollectionFinal {
			deviceUpdateCount++
		}
	}
	if runTotalDevices < deviceUpdateCount {
		runTotalDevices = deviceUpdateCount
	}

	meta := syncChunkMeta{
		syncServiceID:  source.SyncServiceID,
		runID:          runID,
		totalDevices:   runTotalDevices,
		baseChunkIndex: baseChunkIndex,
		runFinalPage:   runFinalPage,
		population:     firstPopulation(population),
	}

	maxChunkSize, maxHosts := sweepResultsChunkLimits()
	chunkRanges, err := splitSyncUpdates(updates, maxChunkSize, maxHosts, meta)
	if err != nil {
		return nil, err
	}

	totalChunks := len(chunkRanges)
	chunks := make([]*proto.ResultsChunk, 0, totalChunks)

	for idx, chunk := range chunkRanges {
		isFinal := runFinalPage && idx == totalChunks-1
		applySyncMeta(chunk, meta, meta.baseChunkIndex+idx, syncMetaTotalChunks(meta, totalChunks), isFinal)

		payload, err := json.Marshal(chunk)
		if err != nil {
			return nil, fmt.Errorf("marshal sync chunk %d: %w", idx, err)
		}

		chunks = append(chunks, &proto.ResultsChunk{
			Data:            payload,
			IsFinal:         isFinal,
			ChunkIndex:      int32(idx),
			TotalChunks:     int32(totalChunks),
			CurrentSequence: runID,
			Timestamp:       time.Now().Unix(),
		})
	}

	return chunks, nil
}

func splitSyncUpdates(
	updates []map[string]interface{},
	maxChunkSize int,
	maxHosts int,
	meta syncChunkMeta,
) ([][]map[string]interface{}, error) {
	if len(updates) == 0 {
		return nil, nil
	}

	chunks := make([][]map[string]interface{}, 0)
	current := make([]map[string]interface{}, 0, maxHosts)
	currentSize := 2

	for _, update := range updates {
		if update == nil {
			continue
		}

		placeholder := buildSyncMeta(meta, 0, 0, false)
		update[syncMetaKey] = placeholder

		encoded, err := json.Marshal(update)
		if err != nil {
			return nil, fmt.Errorf("marshal sync update: %w", err)
		}

		entrySize := len(encoded)
		if len(current) > 0 {
			entrySize++
		}

		if (currentSize+entrySize > maxChunkSize || len(current) >= maxHosts) && len(current) > 0 {
			chunks = append(chunks, current)
			current = make([]map[string]interface{}, 0, maxHosts)
			currentSize = 2
		}

		current = append(current, update)
		currentSize += entrySize
	}

	if len(current) > 0 {
		chunks = append(chunks, current)
	}

	return chunks, nil
}

func applySyncMeta(
	updates []map[string]interface{},
	meta syncChunkMeta,
	chunkIndex int,
	totalChunks int,
	isFinal bool,
) {
	for _, update := range updates {
		if update == nil {
			continue
		}
		update[syncMetaKey] = buildSyncMeta(meta, chunkIndex, totalChunks, isFinal)
	}
}

func syncMetaTotalChunks(meta syncChunkMeta, pageTotalChunks int) int {
	if meta.runFinalPage {
		return meta.baseChunkIndex + pageTotalChunks
	}

	return 0
}

func buildSyncMeta(meta syncChunkMeta, chunkIndex int, totalChunks int, isFinal bool) map[string]interface{} {
	result := map[string]interface{}{
		"sync_service_id": meta.syncServiceID,
		"sync_run_id":     meta.runID,
		"chunk_index":     chunkIndex,
		"total_chunks":    totalChunks,
		"total_devices":   meta.totalDevices,
		"is_final":        isFinal,
	}

	if isFinal && meta.population != nil {
		result["population"] = map[string]interface{}{
			"raw_rows":                       meta.population.RawRows,
			"excluded_rows":                  meta.population.ExcludedRows,
			"invalid_rows":                   meta.population.InvalidRows,
			"valid_occurrences":              meta.population.ValidOccurrences,
			"distinct_source_ids":            meta.population.DistinctSourceIDs,
			"duplicate_occurrences":          meta.population.DuplicateOccurrences,
			"duplicate_source_id_examples":   boundedPopulationExamples(meta.population.DuplicateSourceIDExamples),
			"invalid_row_examples":           boundedPopulationExamples(meta.population.InvalidRowExamples),
			"conflicting_duplicate_ids":      len(meta.population.ConflictingDuplicateIDs),
			"conflicting_duplicate_examples": boundedPopulationExamples(meta.population.ConflictingDuplicateIDs),
		}
	}

	return result
}

func boundedPopulationExamples(values []string) []string {
	if len(values) > syncPopulationExampleLimit {
		values = values[:syncPopulationExampleLimit]
	}

	return append([]string(nil), values...)
}

func firstPopulation(values []*syncsources.PopulationStats) *syncsources.PopulationStats {
	if len(values) == 0 {
		return nil
	}

	return values[0]
}
