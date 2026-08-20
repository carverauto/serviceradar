/*
 * Copyright 2025 Carver Automation Corporation.
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
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"github.com/tetratelabs/wazero"
)

// maxSummaryLen limits error summary length to avoid exceeding message size limits.
// Stack traces from WASM panics can be very long; truncate to keep payloads manageable.
const maxSummaryLen = 2048

func buildPluginErrorResult(assignment *pluginAssignment, summary string) PluginResult {
	observed := time.Now().UTC()

	// Truncate very long summaries (e.g., WASM stack traces) to prevent
	// message size issues during transmission.
	if len(summary) > maxSummaryLen {
		summary = summary[:maxSummaryLen] + "... (truncated)"
	}

	payload := map[string]interface{}{
		"status":      "UNKNOWN",
		"summary":     summary,
		"observed_at": observed.Format(time.RFC3339Nano),
		"labels": map[string]string{
			"assignment_id": assignment.AssignmentID,
			"plugin_id":     assignment.PluginID,
			"plugin_name":   assignment.Name,
		},
	}

	data, _ := json.Marshal(payload)

	return PluginResult{
		AssignmentID: assignment.AssignmentID,
		PluginID:     assignment.PluginID,
		PluginName:   assignment.Name,
		Payload:      data,
		ObservedAt:   observed,
	}
}

// NewPluginManager initializes a new plugin manager.
func NewPluginManager(ctx context.Context, cfg PluginManagerConfig) *PluginManager {
	if ctx == nil {
		ctx = context.Background()
	}

	rootCtx, cancel := context.WithCancel(ctx)

	cacheDir := strings.TrimSpace(cfg.CacheDir)
	if cacheDir == "" {
		cacheDir = filepath.Join(os.TempDir(), "serviceradar", "plugins")
	}

	localStoreDir := strings.TrimSpace(cfg.LocalStoreDir)
	if localStoreDir == "" {
		localStoreDir = cacheDir
	}

	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: pluginDefaultHTTPTimeout}
	}

	artifactClient := cfg.ArtifactHTTPClient
	if artifactClient == nil {
		artifactClient = client
	}

	return &PluginManager{
		logger:                        cfg.Logger,
		cacheDir:                      cacheDir,
		localStoreDir:                 localStoreDir,
		httpClient:                    client,
		artifactHTTPClient:            artifactClient,
		compilationCache:              wazero.NewCompilationCache(),
		credentialBroker:              cfg.CredentialBroker,
		awxCallbackCredentialResolver: cfg.AWXCallbackCredentialResolver,
		artifactUploader:              cfg.ArtifactUploader,
		credentialCache:               make(map[string]credentialBrokerCacheEntry),
		credentialNow:                 time.Now,
		ctx:                           rootCtx,
		cancel:                        cancel,
		runners:                       make(map[string]*pluginRunner),
		streams:                       make(map[string]*pluginAssignment),
		actions:                       make(map[string]*pluginAssignment),
		activeActions:                 make(map[string]struct{}),
		streamExecutions:              make(map[uint64]activePluginStreamExecution),
		results:                       make(chan PluginResult, 1024),
		signals:                       make(chan PluginSignalTelemetry, 1024),
		conditions:                    newPluginConditionDebouncer(time.Now),
		states:                        make(map[string]*assignmentState),
		stateNow:                      time.Now,
	}
}

// SetArtifactUploader installs the trusted host-side artifact uploader.
func (m *PluginManager) SetArtifactUploader(uploader PluginArtifactUploader) {
	if m == nil {
		return
	}

	m.artifactMu.Lock()
	defer m.artifactMu.Unlock()
	m.artifactUploader = uploader
}

// SetCredentialBroker installs the trusted host-side credential resolver.
func (m *PluginManager) SetCredentialBroker(resolver CredentialBrokerResolver) {
	if m == nil {
		return
	}

	m.credentialMu.Lock()
	defer m.credentialMu.Unlock()
	m.credentialBroker = resolver
}

// SetAWXCallbackCredentialEnvelopeResolver installs the selected-agent,
// single-resolution launch-envelope boundary. Resolved callback inputs remain
// memory-only and are never added to AgentCommandBus payloads or plugin config.
func (m *PluginManager) SetAWXCallbackCredentialEnvelopeResolver(
	resolver AWXCallbackCredentialEnvelopeResolver,
) {
	if m == nil {
		return
	}

	m.awxCallbackCredentialMu.Lock()
	defer m.awxCallbackCredentialMu.Unlock()
	m.awxCallbackCredentialResolver = resolver
}

// ApplyConfig applies plugin assignments from config, replacing existing runners.
func (m *PluginManager) ApplyConfig(cfg *proto.PluginConfig) {
	if m == nil {
		return
	}

	limits := engineLimitsFromProto(cfg)
	m.setLimits(limits)

	assignments := make([]*pluginAssignment, 0)
	if cfg != nil {
		for _, assignment := range cfg.Assignments {
			if assignment == nil {
				continue
			}
			if !assignment.Enabled {
				continue
			}
			assignments = append(assignments, newPluginAssignment(assignment, m.logger))
		}
	}

	configHash := buildPluginConfigHash(limits, assignments)
	if m.configUnchanged(configHash) {
		// The fingerprint deliberately excludes the gateway-signed artifact
		// download request: the token is short-TTL and re-minted by the
		// control plane on every config generation. Adopt the fresh
		// credentials in place so a later cache miss (eviction, restart)
		// does not retry the download with a stale token (401), without
		// restarting runners (task 3.3, refactor-device-identity-reconciliation).
		m.refreshDownloadCredentials(assignments)
		m.refreshPluginHostAuthorities(assignments)
		m.logger.Debug().Str("config_hash", configHash).Msg("Plugin config unchanged; refreshed download credentials only")

		return
	}

	admitted, rejected, usage := m.admitAssignments(assignments, limits)
	m.updateConfigStats(len(assignments), len(admitted), len(rejected), usage)

	m.refreshAssignmentStates(admitted)

	nextRunners := make(map[string]*pluginRunner)
	nextStreams := make(map[string]*pluginAssignment)
	nextActions := make(map[string]*pluginAssignment)
	nextStreamingGenerations := make(map[string]string)

	for _, assignment := range admitted {
		if assignment.isStreaming() {
			nextStreams[assignment.AssignmentID] = assignment
			nextStreamingGenerations[assignment.AssignmentID] = assignment.generation
			continue
		}
		if assignment.isActionOnly() {
			nextActions[assignment.AssignmentID] = assignment
			continue
		}
		nextRunners[assignment.AssignmentID] = newPluginRunner(m, assignment)
	}

	m.mu.Lock()
	prev := m.runners
	m.runners = nextRunners
	m.streams = nextStreams
	m.actions = nextActions
	m.mu.Unlock()

	m.cancelRevokedStreamingExecutions(nextStreamingGenerations)

	for _, runner := range prev {
		runner.stop()
	}

	for _, assignment := range rejected {
		m.tryEnqueueResult(buildPluginErrorResult(assignment, "admission denied: engine limits exceeded"))
	}

	for _, assignment := range admitted {
		if assignment.isStreaming() {
			m.prefetchAssignment(assignment)
			continue
		}
		if assignment.isActionOnly() {
			m.prefetchAssignment(assignment)
			continue
		}

		nextRunners[assignment.AssignmentID].start(m.ctx)
		m.prefetchAssignment(assignment)
	}

	m.setConfigHash(configHash)
}

// refreshPluginHostAuthorities adopts volatile broker lease fields without
// restarting a runner. Stable origin/rule/target/grant scope is part of the
// config fingerprint, so only an authority with the identical stable hash can
// replace the currently retained bindings.
func (m *PluginManager) refreshPluginHostAuthorities(incoming []*pluginAssignment) {
	if m == nil || len(incoming) == 0 {
		return
	}

	byID := make(map[string]*pluginAssignment, len(incoming))
	for _, assignment := range incoming {
		if assignment != nil && assignment.AssignmentID != "" {
			byID[assignment.AssignmentID] = assignment
		}
	}

	m.mu.RLock()
	current := make([]*pluginAssignment, 0, len(m.runners)+len(m.streams)+len(m.actions))
	for _, runner := range m.runners {
		if runner != nil && runner.assignment != nil {
			current = append(current, runner.assignment)
		}
	}
	for _, assignment := range m.streams {
		if assignment != nil {
			current = append(current, assignment)
		}
	}
	for _, assignment := range m.actions {
		if assignment != nil {
			current = append(current, assignment)
		}
	}
	m.mu.RUnlock()

	for _, assignment := range current {
		assignment.refreshPluginHostAuthority(byID[assignment.AssignmentID])
	}
}

// refreshDownloadCredentials copies the freshly minted artifact download
// URL/token from incoming assignments onto the currently held assignments
// (scheduled runners, streaming registrations, and action-only registrations)
// keyed by assignment ID.
func (m *PluginManager) refreshDownloadCredentials(incoming []*pluginAssignment) {
	if m == nil || len(incoming) == 0 {
		return
	}

	byID := make(map[string]*pluginAssignment, len(incoming))
	for _, assignment := range incoming {
		if assignment == nil || assignment.AssignmentID == "" {
			continue
		}
		byID[assignment.AssignmentID] = assignment
	}

	m.mu.Lock()
	current := make([]*pluginAssignment, 0, len(m.runners)+len(m.streams)+len(m.actions))
	for _, runner := range m.runners {
		if runner != nil && runner.assignment != nil {
			current = append(current, runner.assignment)
		}
	}
	for _, assignment := range m.streams {
		if assignment != nil {
			current = append(current, assignment)
		}
	}
	for _, assignment := range m.actions {
		if assignment != nil {
			current = append(current, assignment)
		}
	}
	m.mu.Unlock()

	for _, assignment := range current {
		fresh, ok := byID[assignment.AssignmentID]
		if !ok {
			continue
		}
		downloadURL, downloadToken := fresh.downloadCredentials()
		assignment.setDownloadCredentials(downloadURL, downloadToken)
	}
}

func (m *PluginManager) setLimits(limits pluginEngineLimits) {
	m.limitsMu.Lock()
	defer m.limitsMu.Unlock()
	m.limits = limits
}

func (m *PluginManager) acquireSlot() bool {
	m.limitsMu.Lock()
	defer m.limitsMu.Unlock()

	if m.limits.MaxConcurrent <= 0 {
		m.concurrentActive++
		return true
	}
	if m.concurrentActive >= m.limits.MaxConcurrent {
		return false
	}
	m.concurrentActive++
	return true
}

func (m *PluginManager) releaseSlot() {
	m.limitsMu.Lock()
	defer m.limitsMu.Unlock()
	if m.concurrentActive > 0 {
		m.concurrentActive--
	}
}

func (m *PluginManager) acquireAction(assignmentID string) bool {
	m.actionMu.Lock()
	defer m.actionMu.Unlock()

	if _, exists := m.activeActions[assignmentID]; exists {
		return false
	}

	m.activeActions[assignmentID] = struct{}{}
	return true
}

func (m *PluginManager) releaseAction(assignmentID string) {
	m.actionMu.Lock()
	defer m.actionMu.Unlock()

	delete(m.activeActions, assignmentID)
}

func (m *PluginManager) reserveConnection() bool {
	m.limitsMu.Lock()
	defer m.limitsMu.Unlock()

	if m.limits.MaxOpenConnections > 0 && m.openConnections >= m.limits.MaxOpenConnections {
		return false
	}

	m.openConnections++
	return true
}

func (m *PluginManager) releaseConnection() {
	m.limitsMu.Lock()
	defer m.limitsMu.Unlock()
	if m.openConnections > 0 {
		m.openConnections--
	}
}

func (m *PluginManager) updateConfigStats(total, admitted, rejected int, usage engineUsage) {
	m.statsMu.Lock()
	defer m.statsMu.Unlock()

	m.stats.assignmentsTotal = total
	m.stats.assignmentsAdmitted = admitted
	m.stats.assignmentsRejected = rejected
	m.stats.requestedMemoryMB = usage.memoryMB
	m.stats.requestedCPUMS = usage.cpuMS
	m.stats.requestedConnections = usage.connections
	m.stats.lastConfigAt = time.Now().UTC()
}

func (m *PluginManager) configUnchanged(hash string) bool {
	m.configMu.Lock()
	defer m.configMu.Unlock()
	return m.lastConfigSHA != "" && m.lastConfigSHA == hash
}

func (m *PluginManager) setConfigHash(hash string) {
	m.configMu.Lock()
	defer m.configMu.Unlock()
	m.lastConfigSHA = hash
}

func (m *PluginManager) recordExecution(success bool) {
	m.statsMu.Lock()
	defer m.statsMu.Unlock()

	now := time.Now().UTC()
	m.stats.execTotal++
	m.stats.lastExecAt = now
	if !success {
		m.stats.execFailures++
		m.stats.lastFailureAt = now
	}
}

func (m *PluginManager) Snapshot() PluginEngineSnapshot {
	now := time.Now().UTC()

	m.limitsMu.Lock()
	limits := m.limits
	active := m.concurrentActive
	openConnections := m.openConnections
	m.limitsMu.Unlock()

	m.statsMu.Lock()
	stats := m.stats
	m.statsMu.Unlock()

	return PluginEngineSnapshot{
		ObservedAt:           now,
		Limits:               limits,
		RequestedMemoryMB:    stats.requestedMemoryMB,
		RequestedCPUMS:       stats.requestedCPUMS,
		RequestedConnections: stats.requestedConnections,
		AssignmentsTotal:     stats.assignmentsTotal,
		AssignmentsAdmitted:  stats.assignmentsAdmitted,
		AssignmentsRejected:  stats.assignmentsRejected,
		ActiveExecutions:     active,
		OpenConnections:      openConnections,
		ExecTotal:            stats.execTotal,
		ExecFailures:         stats.execFailures,
		LastExecAt:           stats.lastExecAt,
		LastFailureAt:        stats.lastFailureAt,
		LastConfigAt:         stats.lastConfigAt,
	}
}

func (m *PluginManager) DebugSnapshot() PluginEngineDebugSnapshot {
	if m == nil {
		return PluginEngineDebugSnapshot{}
	}

	engine := m.Snapshot()

	type assignmentWithMode struct {
		assignment *pluginAssignment
		mode       string
	}

	m.mu.RLock()
	assignments := make(
		[]assignmentWithMode,
		0,
		len(m.runners)+len(m.streams)+len(m.actions),
	)
	for _, runner := range m.runners {
		if runner == nil || runner.assignment == nil {
			continue
		}
		assignments = append(assignments, assignmentWithMode{
			assignment: runner.assignment,
			mode:       string(pluginExecutionModeScheduled),
		})
	}
	for _, assignment := range m.streams {
		if assignment == nil {
			continue
		}
		assignments = append(assignments, assignmentWithMode{
			assignment: assignment,
			mode:       string(pluginExecutionModeStreaming),
		})
	}
	for _, assignment := range m.actions {
		if assignment == nil {
			continue
		}
		assignments = append(assignments, assignmentWithMode{
			assignment: assignment,
			mode:       string(pluginExecutionModeAction),
		})
	}
	m.mu.RUnlock()

	out := PluginEngineDebugSnapshot{
		Engine:      engine,
		Assignments: make([]PluginEngineAssignmentSnapshot, 0, len(assignments)),
	}

	for _, item := range assignments {
		out.Assignments = append(out.Assignments, m.assignmentDebugSnapshot(item.assignment, item.mode))
	}

	sort.Slice(out.Assignments, func(i, j int) bool {
		return out.Assignments[i].AssignmentID < out.Assignments[j].AssignmentID
	})

	return out
}

func (m *PluginManager) assignmentDebugSnapshot(
	assignment *pluginAssignment,
	mode string,
) PluginEngineAssignmentSnapshot {
	if assignment == nil {
		return PluginEngineAssignmentSnapshot{}
	}

	capabilities := make([]string, 0, len(assignment.Capabilities))
	for capability := range assignment.Capabilities {
		capabilities = append(capabilities, capability)
	}
	sort.Strings(capabilities)

	state := m.readAssignmentState(assignment.AssignmentID)
	firstSeenAt := ""
	if !state.firstSeen.IsZero() {
		firstSeenAt = state.firstSeen.UTC().Format(time.RFC3339Nano)
	}

	downloadURL, downloadToken := assignment.downloadCredentials()

	return PluginEngineAssignmentSnapshot{
		AssignmentID:         assignment.AssignmentID,
		PluginID:             assignment.PluginID,
		PackageID:            assignment.PackageID,
		Version:              assignment.Version,
		Name:                 assignment.Name,
		Entrypoint:           assignment.Entrypoint,
		Runtime:              assignment.Runtime,
		Mode:                 mode,
		Outputs:              assignment.Outputs,
		Capabilities:         capabilities,
		IntervalSeconds:      int64(assignment.Interval.Seconds()),
		TimeoutSeconds:       int64(assignment.Timeout.Seconds()),
		WasmObject:           assignment.WasmObject,
		ContentHash:          assignment.ContentHash,
		DownloadHost:         downloadURLHost(downloadURL),
		DownloadTokenPresent: downloadToken != "",
		Ready:                state.ready,
		FirstSeenAt:          firstSeenAt,
	}
}

func (m *PluginManager) readAssignmentState(assignmentID string) assignmentState {
	if m == nil {
		return assignmentState{}
	}

	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	state := m.states[assignmentID]
	if state == nil {
		return assignmentState{}
	}

	return *state
}

func downloadURLHost(rawURL string) string {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || parsed == nil {
		return ""
	}
	return parsed.Host
}

type engineUsage struct {
	memoryMB    int
	cpuMS       int
	connections int
	count       int
}

func (m *PluginManager) admitAssignments(
	assignments []*pluginAssignment,
	limits pluginEngineLimits,
) ([]*pluginAssignment, []*pluginAssignment, engineUsage) {
	if len(assignments) == 0 {
		return nil, nil, engineUsage{}
	}

	sort.Slice(assignments, func(i, j int) bool {
		return assignments[i].AssignmentID < assignments[j].AssignmentID
	})

	usage := engineUsage{}
	admitted := make([]*pluginAssignment, 0, len(assignments))
	rejected := make([]*pluginAssignment, 0)

	for _, assignment := range assignments {
		req := normalizeResources(assignment.Resources)
		if !fitsLimits(usage, req, limits) {
			m.logger.Warn().
				Str("assignment_id", assignment.AssignmentID).
				Int("requested_memory_mb", req.RequestedMemoryMB).
				Int("requested_cpu_ms", req.RequestedCPUMS).
				Int("requested_connections", req.MaxOpenConnections).
				Msg("Plugin assignment rejected by engine limits")
			rejected = append(rejected, assignment)
			continue
		}

		usage.memoryMB += req.RequestedMemoryMB
		usage.cpuMS += req.RequestedCPUMS
		usage.connections += req.MaxOpenConnections
		usage.count++
		admitted = append(admitted, assignment)
	}

	return admitted, rejected, usage
}

func normalizeResources(resources pluginResources) pluginResources {
	if resources.RequestedMemoryMB < 0 {
		resources.RequestedMemoryMB = 0
	}
	if resources.RequestedCPUMS < 0 {
		resources.RequestedCPUMS = 0
	}
	if resources.MaxOpenConnections < 0 {
		resources.MaxOpenConnections = 0
	}
	return resources
}

func fitsLimits(usage engineUsage, req pluginResources, limits pluginEngineLimits) bool {
	if limits.MaxMemoryMB > 0 && usage.memoryMB+req.RequestedMemoryMB > limits.MaxMemoryMB {
		return false
	}
	if limits.MaxCPUMS > 0 && usage.cpuMS+req.RequestedCPUMS > limits.MaxCPUMS {
		return false
	}
	if limits.MaxConcurrent > 0 && usage.count+1 > limits.MaxConcurrent {
		return false
	}
	if limits.MaxOpenConnections > 0 && usage.connections+req.MaxOpenConnections > limits.MaxOpenConnections {
		return false
	}
	return true
}

// Stop stops all plugin runners.
func (m *PluginManager) Stop() {
	if m == nil {
		return
	}

	m.cancel()
	m.cancelAllStreamingExecutions()

	m.mu.Lock()
	prev := m.runners
	m.runners = make(map[string]*pluginRunner)
	m.streams = make(map[string]*pluginAssignment)
	m.actions = make(map[string]*pluginAssignment)
	m.mu.Unlock()

	for _, runner := range prev {
		runner.stop()
	}

	m.cacheCloseOnce.Do(func() {
		if m.compilationCache != nil {
			_ = m.compilationCache.Close(context.Background())
		}
	})
}

func (m *PluginManager) registerStreamingExecution(
	ctx context.Context,
	assignment *pluginAssignment,
) (context.Context, uint64, error) {
	if m == nil || assignment == nil || assignment.generation == "" {
		return nil, 0, errStreamingPluginAssignmentNotFound
	}
	if ctx == nil {
		ctx = context.Background()
	}

	m.mu.RLock()
	current, ok := m.streams[assignment.AssignmentID]
	if !ok || current == nil || current.generation != assignment.generation {
		m.mu.RUnlock()
		return nil, 0, errStreamingPluginAssignmentNotFound
	}

	runCtx, cancel := context.WithCancel(ctx)
	m.streamExecutionMu.Lock()
	m.nextStreamExecutionID++
	id := m.nextStreamExecutionID
	m.streamExecutions[id] = activePluginStreamExecution{
		assignmentID: assignment.AssignmentID,
		generation:   assignment.generation,
		cancel:       cancel,
	}
	m.streamExecutionMu.Unlock()
	m.mu.RUnlock()

	return runCtx, id, nil
}

func (m *PluginManager) unregisterStreamingExecution(id uint64) {
	if m == nil || id == 0 {
		return
	}

	m.streamExecutionMu.Lock()
	delete(m.streamExecutions, id)
	m.streamExecutionMu.Unlock()
}

func (m *PluginManager) cancelRevokedStreamingExecutions(activeGenerations map[string]string) {
	if m == nil {
		return
	}

	cancels := make([]context.CancelFunc, 0)
	m.streamExecutionMu.Lock()
	for _, execution := range m.streamExecutions {
		if activeGenerations[execution.assignmentID] != execution.generation && execution.cancel != nil {
			cancels = append(cancels, execution.cancel)
		}
	}
	m.streamExecutionMu.Unlock()

	for _, cancel := range cancels {
		cancel()
	}
}

func (m *PluginManager) cancelAllStreamingExecutions() {
	if m == nil {
		return
	}

	cancels := make([]context.CancelFunc, 0)
	m.streamExecutionMu.Lock()
	for _, execution := range m.streamExecutions {
		if execution.cancel != nil {
			cancels = append(cancels, execution.cancel)
		}
	}
	m.streamExecutionMu.Unlock()

	for _, cancel := range cancels {
		cancel()
	}
}

func (m *PluginManager) pluginAssignmentGenerationActive(
	assignment *pluginAssignment,
	mode pluginExecutionMode,
) bool {
	if m == nil || assignment == nil || assignment.generation == "" {
		return false
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	switch mode {
	case pluginExecutionModeStreaming:
		current := m.streams[assignment.AssignmentID]
		if current != nil && current.generation == assignment.generation {
			assignment.refreshPluginHostAuthority(current)
			return true
		}
		return false
	case pluginExecutionModeScheduled, pluginExecutionModeAction:
		runner := m.runners[assignment.AssignmentID]
		if runner != nil && runner.assignment != nil &&
			runner.assignment.generation == assignment.generation {
			assignment.refreshPluginHostAuthority(runner.assignment)
			return true
		}
		return false
	default:
		return false
	}
}

// ProxmoxAssignmentPolicyAcks returns only assignment bindings that trusted
// host code successfully parsed and retained from the currently active plugin
// config. The deterministic ordering keeps hello/config-ack evidence stable.
func (m *PluginManager) ProxmoxAssignmentPolicyAcks() []*proto.PluginAssignmentPolicyAck {
	if m == nil {
		return nil
	}

	m.mu.RLock()
	assignments := make([]*pluginAssignment, 0, len(m.runners)+len(m.streams))
	for _, runner := range m.runners {
		if runner != nil && runner.assignment != nil {
			assignments = append(assignments, runner.assignment)
		}
	}
	for _, assignment := range m.streams {
		if assignment != nil {
			assignments = append(assignments, assignment)
		}
	}
	m.mu.RUnlock()

	acks := make([]*proto.PluginAssignmentPolicyAck, 0, len(assignments))
	seen := make(map[string]struct{}, len(assignments))
	for _, assignment := range assignments {
		if assignment == nil || assignment.AssignmentID == "" ||
			!assignment.proxmoxHostAuthorityRequired ||
			!isProxmoxHostAuthorityAssignment(assignment.PluginID, assignment.Entrypoint) {
			continue
		}

		binding, ok := assignment.proxmoxAssignmentPolicyBinding()
		if !ok {
			continue
		}
		key := assignment.AssignmentID + "\x00" + assignment.PluginID
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		acks = append(acks, &proto.PluginAssignmentPolicyAck{
			AssignmentId:                assignment.AssignmentID,
			PluginId:                    assignment.PluginID,
			AssignmentPolicyVersion:     binding.PolicyVersion,
			AssignmentPolicyFingerprint: binding.Fingerprint,
		})
	}

	sort.Slice(acks, func(i, j int) bool {
		if acks[i].AssignmentId == acks[j].AssignmentId {
			return acks[i].PluginId < acks[j].PluginId
		}
		return acks[i].AssignmentId < acks[j].AssignmentId
	})

	return acks
}

// StreamingAssignments returns the currently admitted camera streaming plugin assignments.
func (m *PluginManager) StreamingAssignments() []StreamingPluginAssignment {
	if m == nil {
		return nil
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	assignments := make([]StreamingPluginAssignment, 0, len(m.streams))
	for _, assignment := range m.streams {
		assignments = append(assignments, assignment.streamingSnapshot())
	}

	sort.Slice(assignments, func(i, j int) bool {
		return assignments[i].AssignmentID < assignments[j].AssignmentID
	})

	return assignments
}

// StreamingAssignment returns a single admitted camera streaming plugin assignment by id.
func (m *PluginManager) StreamingAssignment(assignmentID string) (StreamingPluginAssignment, bool) {
	if m == nil {
		return StreamingPluginAssignment{}, false
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	assignment, ok := m.streams[strings.TrimSpace(assignmentID)]
	if !ok || assignment == nil {
		return StreamingPluginAssignment{}, false
	}

	return assignment.streamingSnapshot(), true
}

// OpenCameraRelayStream starts a streaming plugin execution and returns a chunk
// stream that the camera relay manager can upload using the normal relay path.
func (m *PluginManager) OpenCameraRelayStream(
	ctx context.Context,
	assignmentID string,
	spec cameraRelaySessionSpec,
) (cameraRelayChunkStream, error) {
	if m == nil {
		return nil, errCameraRelayPluginUnavailable
	}

	assignment, ok := m.lookupStreamingAssignment(assignmentID)
	if !ok {
		return nil, fmt.Errorf("%w %q", errStreamingPluginAssignmentNotFound, strings.TrimSpace(assignmentID))
	}

	if !m.acquireSlot() {
		return nil, errStreamingPluginAdmissionDenied
	}
	streamCtx, cancel := context.WithCancel(ctx)
	runCtx, executionID, err := m.registerStreamingExecution(streamCtx, assignment)
	if err != nil {
		cancel()
		m.releaseSlot()
		return nil, err
	}

	wasm, err := m.loadWasm(runCtx, assignment)
	if err != nil {
		cancel()
		m.unregisterStreamingExecution(executionID)
		m.releaseSlot()
		return nil, err
	}

	configJSON, err := buildStreamingPluginConfig(assignment.ParamsJSON, spec)
	if err != nil {
		cancel()
		m.unregisterStreamingExecution(executionID)
		m.releaseSlot()
		return nil, err
	}

	stream := newPluginCameraRelayStream(cancel)
	bridge := newPluginCameraMediaBridge(stream)

	go func() {
		defer cancel()
		defer m.unregisterStreamingExecution(executionID)
		defer m.releaseSlot()

		execErr := m.executeStreamingPlugin(runCtx, assignment, wasm, configJSON, bridge)
		switch {
		case execErr != nil:
			m.recordExecution(false)
			m.logger.Warn().
				Err(execErr).
				Str("assignment_id", assignment.AssignmentID).
				Str("relay_session_id", spec.RelaySessionID).
				Msg("Streaming plugin execution failed")
			stream.finish(execErr)

		case !bridge.hasOpened():
			m.recordExecution(false)
			stream.finish(errStreamingPluginMediaSessionMissing)

		default:
			m.recordExecution(true)
			bridge.finish(io.EOF)
		}
	}()

	return stream, nil
}

func (m *PluginManager) executeStreamingPlugin(
	ctx context.Context,
	assignment *pluginAssignment,
	wasm []byte,
	configJSON []byte,
	bridge *pluginCameraMediaBridge,
) error {
	if m.streamExecutor != nil {
		return m.streamExecutor(ctx, assignment, wasm, configJSON, bridge)
	}
	return m.executeStreamingWithWasm(ctx, assignment, wasm, configJSON, bridge)
}

func (m *PluginManager) lookupStreamingAssignment(assignmentID string) (*pluginAssignment, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	assignment, ok := m.streams[strings.TrimSpace(assignmentID)]
	return assignment, ok
}

func (m *PluginManager) lookupRunnerAssignment(assignmentID string) (*pluginAssignment, bool) {
	if m == nil {
		return nil, false
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	runner, ok := m.runners[strings.TrimSpace(assignmentID)]
	if ok && runner != nil && runner.assignment != nil {
		return runner.assignment, true
	}
	action, ok := m.actions[strings.TrimSpace(assignmentID)]
	return action, ok && action != nil
}

// DrainResults returns up to max pending results.
func (m *PluginManager) DrainResults(max int) []PluginResult {
	if m == nil || max <= 0 {
		return nil
	}

	results := make([]PluginResult, 0, max)
	for i := 0; i < max; i++ {
		select {
		case res := <-m.results:
			results = append(results, res)
		default:
			return results
		}
	}

	return results
}

// enqueueResult waits until the result is admitted to the bounded queue or the
// plugin execution is canceled. Wasm callers must not advance to the next page
// until this returns nil.
func (m *PluginManager) enqueueResult(ctx context.Context, result PluginResult) error {
	managerCtx := m.ctx
	if managerCtx == nil {
		managerCtx = context.Background()
	}
	if ctx == nil {
		ctx = context.Background()
	}

	select {
	case m.results <- result:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-managerCtx.Done():
		return managerCtx.Err()
	}
}

// tryEnqueueResult preserves best-effort reporting for control-plane errors.
// Those paths can run on the same loop that drains results, so blocking there
// would deadlock queue recovery.
func (m *PluginManager) tryEnqueueResult(result PluginResult) {
	select {
	case m.results <- result:
	default:
		m.logger.Warn().
			Str("assignment_id", result.AssignmentID).
			Msg("Plugin result dropped due to backpressure")
	}
}

// DrainSignals returns up to max pending plugin-emitted telemetry batches.
func (m *PluginManager) DrainSignals(max int) []PluginSignalTelemetry {
	if m == nil || max <= 0 {
		return nil
	}

	signals := make([]PluginSignalTelemetry, 0, max)
	for i := 0; i < max; i++ {
		select {
		case signal := <-m.signals:
			signals = append(signals, signal)
		default:
			return signals
		}
	}

	return signals
}

func (m *PluginManager) enqueueSignal(signal PluginSignalTelemetry) {
	select {
	case m.signals <- signal:
	default:
		m.logger.Warn().
			Str("assignment_id", signal.AssignmentID).
			Str("plugin_id", signal.PluginID).
			Msg("Plugin telemetry dropped due to backpressure")
	}
}

type pluginRunner struct {
	manager    *PluginManager
	assignment *pluginAssignment
	cancel     context.CancelFunc
	done       chan struct{}
}

func newPluginRunner(manager *PluginManager, assignment *pluginAssignment) *pluginRunner {
	return &pluginRunner{
		manager:    manager,
		assignment: assignment,
		done:       make(chan struct{}),
	}
}

func (r *pluginRunner) start(ctx context.Context) {
	runCtx, cancel := context.WithCancel(ctx)
	r.cancel = cancel

	go func() {
		defer close(r.done)

		interval := r.assignment.Interval
		if interval <= 0 {
			interval = pluginDefaultInterval
		}

		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		r.runOnce(runCtx)

		for {
			select {
			case <-runCtx.Done():
				return
			case <-ticker.C:
				r.runOnce(runCtx)
			}
		}
	}()
}

func (r *pluginRunner) stop() {
	if r.cancel != nil {
		r.cancel()
	}
	<-r.done
}

func (r *pluginRunner) runOnce(ctx context.Context) {
	timeout := r.assignment.Timeout
	if timeout <= 0 {
		timeout = pluginDefaultTimeout
	}

	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	if !r.manager.acquireSlot() {
		r.manager.recordExecution(false)
		r.manager.tryEnqueueResult(buildPluginErrorResult(r.assignment, "admission denied: max concurrent reached"))
		return
	}
	defer r.manager.releaseSlot()

	wasm, err := r.manager.loadWasm(runCtx, r.assignment)
	if err != nil {
		if r.manager.shouldSkipWarmup(r.assignment) {
			r.manager.logger.Info().
				Err(err).
				Str("assignment_id", r.assignment.AssignmentID).
				Msg("Plugin wasm not ready; deferring execution")
			return
		}
		r.manager.recordExecution(false)
		r.manager.tryEnqueueResult(buildPluginErrorResult(r.assignment, fmt.Sprintf("execution failed: %s", err)))
		r.manager.logger.Warn().
			Err(err).
			Str("assignment_id", r.assignment.AssignmentID).
			Msg("Plugin execution failed")
		return
	}

	if err := r.manager.executeWithWasm(runCtx, r.assignment, wasm); err != nil {
		r.manager.recordExecution(false)
		r.manager.tryEnqueueResult(buildPluginErrorResult(r.assignment, fmt.Sprintf("execution failed: %s", err)))
		r.manager.logger.Warn().
			Err(err).
			Str("assignment_id", r.assignment.AssignmentID).
			Msg("Plugin execution failed")
		return
	}

	r.manager.recordExecution(true)
}

// RunAction executes a configured non-streaming plugin assignment on demand for
// a northbound action command. The plugin receives its normal assignment config
// plus an action_invocation envelope from the command payload.
func (m *PluginManager) RunAction(ctx context.Context, assignmentID string, invocationPayload json.RawMessage, timeout time.Duration) ([]byte, error) {
	if m == nil {
		return nil, errPluginAssignmentNotFound
	}

	assignment, ok := m.lookupRunnerAssignment(assignmentID)
	if !ok {
		return nil, fmt.Errorf("%w %q", errPluginAssignmentNotFound, strings.TrimSpace(assignmentID))
	}

	// The notify:v1 gate runs before admission, before the module is loaded, and
	// before any part of the delivery request reaches guest memory. Denial here
	// is the only thing that makes notify:v1 a real permission rather than a
	// declaration in a manifest allowlist.
	if err := m.authorizeNotificationDelivery(assignment, invocationPayload); err != nil {
		m.recordExecution(false)
		return nil, err
	}

	if timeout <= 0 {
		timeout = assignment.Timeout
	}
	if timeout <= 0 {
		timeout = pluginDefaultTimeout
	}

	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	if !m.acquireAction(assignment.AssignmentID) {
		m.recordExecution(false)
		return nil, fmt.Errorf("%w %q", errPluginActionAlreadyRunning, assignment.AssignmentID)
	}
	defer m.releaseAction(assignment.AssignmentID)

	if !m.acquireSlot() {
		m.recordExecution(false)
		return nil, errPluginAdmissionDenied
	}
	defer m.releaseSlot()

	wasm, err := m.loadWasm(runCtx, assignment)
	if err != nil {
		m.recordExecution(false)
		return nil, err
	}

	configJSON, err := buildActionPluginConfig(assignment.ParamsJSON, invocationPayload)
	if err != nil {
		m.recordExecution(false)
		return nil, err
	}

	credentialGrants, err := pluginActionCredentialGrants(invocationPayload)
	if err != nil {
		m.recordExecution(false)
		return nil, err
	}

	entrypoint := notificationActionEntrypoint(assignment, invocationPayload)
	result, err := m.executeActionWithWasm(runCtx, assignment, entrypoint, wasm, configJSON, credentialGrants, nil, nil)
	if err == nil && assignment.ingestsActionResults() {
		result, err = m.enqueueActionResult(runCtx, assignment, result)
	}
	m.recordExecution(err == nil)
	return result, err
}

// RunPluginVerb executes the run_check-style entrypoint of the runner
// assignment matching pluginID on demand, passing configJSON straight through
// as the plugin config. Credential broker grants ride outside the config so
// material is injected at the host HTTP boundary and never enters the Wasm
// module. Used for command verbs (e.g. awx.*) that address a plugin by plugin
// id rather than by assignment id.
func (m *PluginManager) RunPluginVerb(
	ctx context.Context,
	pluginID string,
	configJSON json.RawMessage,
	credentialGrants []credentialBrokerGrant,
	timeout time.Duration,
) ([]byte, error) {
	return m.runPluginVerb(ctx, pluginID, configJSON, credentialGrants, nil, nil, timeout)
}

// RunPluginVerbWithAuthorizedRequestBody runs one verb while retaining exact
// control-plane-produced request bytes solely in the trusted host boundary.
// The bytes are never added to the Wasm configuration.
func (m *PluginManager) RunPluginVerbWithAuthorizedRequestBody(
	ctx context.Context,
	pluginID string,
	configJSON json.RawMessage,
	credentialGrants []credentialBrokerGrant,
	authorizedRequestBody []byte,
	timeout time.Duration,
) ([]byte, error) {
	return m.runPluginVerb(
		ctx,
		pluginID,
		configJSON,
		credentialGrants,
		authorizedRequestBody,
		nil,
		timeout,
	)
}

// RunPluginVerbWithAWXCallbackCredential runs one AWX verb with a memory-only
// credential input available solely to the exact /api/v2/credentials/ POST
// rewrite in the trusted host HTTP boundary.
func (m *PluginManager) RunPluginVerbWithAWXCallbackCredential(
	ctx context.Context,
	pluginID string,
	configJSON json.RawMessage,
	credentialGrants []credentialBrokerGrant,
	callbackCredential *awxCallbackCredentialMemoryInput,
	timeout time.Duration,
) ([]byte, error) {
	if callbackCredential == nil {
		return nil, errAWXCallbackCredentialInputMissing
	}
	// Ownership transfers at this boundary. Destruction is guaranteed even if
	// assignment lookup, Wasm loading/instantiation, preflight verification, or
	// the sentinel POST fails before the plugin returns normally.
	defer callbackCredential.destroy()
	return m.runPluginVerb(ctx, pluginID, configJSON, credentialGrants, nil, callbackCredential, timeout)
}

func (m *PluginManager) runPluginVerb(
	ctx context.Context,
	pluginID string,
	configJSON json.RawMessage,
	credentialGrants []credentialBrokerGrant,
	authorizedRequestBody []byte,
	callbackCredential *awxCallbackCredentialMemoryInput,
	timeout time.Duration,
) ([]byte, error) {
	if m == nil {
		return nil, errPluginAssignmentNotFound
	}

	assignment, ok := m.lookupRunnerAssignmentByPluginID(pluginID)
	if !ok {
		return nil, fmt.Errorf("%w for plugin %q", errPluginAssignmentNotFound, strings.TrimSpace(pluginID))
	}

	// Gated here as well as in RunAction. Notification dispatch is specified to
	// ride plugin.run_action, so this path should never carry a delivery
	// envelope - but "should never" is not a permission check, and a capability
	// with one guarded entrance and one unguarded entrance is not enforced.
	if err := m.authorizeNotificationDelivery(assignment, configJSON); err != nil {
		m.recordExecution(false)
		return nil, err
	}

	if timeout <= 0 {
		timeout = assignment.Timeout
	}
	if timeout <= 0 {
		timeout = pluginDefaultTimeout
	}

	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	if !m.acquireSlot() {
		m.recordExecution(false)
		return nil, errPluginAdmissionDenied
	}
	defer m.releaseSlot()

	wasm, err := m.loadWasm(runCtx, assignment)
	if err != nil {
		m.recordExecution(false)
		return nil, err
	}

	result, err := m.executeActionWithWasm(
		runCtx,
		assignment,
		assignment.Entrypoint,
		wasm,
		configJSON,
		credentialGrants,
		authorizedRequestBody,
		callbackCredential,
	)
	m.recordExecution(err == nil)
	return result, err
}

// lookupRunnerAssignmentByPluginID finds the runner assignment for an exact
// plugin id. Exactness matters: the awx wasm is also assigned as
// "awx-inventory-sync" with a different entrypoint, and command verbs must
// never run through that assignment.
func (m *PluginManager) lookupRunnerAssignmentByPluginID(pluginID string) (*pluginAssignment, bool) {
	if m == nil {
		return nil, false
	}

	pluginID = strings.TrimSpace(pluginID)
	if pluginID == "" {
		return nil, false
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	for _, runner := range m.runners {
		if runner == nil || runner.assignment == nil {
			continue
		}
		if runner.assignment.PluginID == pluginID {
			return runner.assignment, true
		}
	}
	for _, assignment := range m.actions {
		if assignment != nil && assignment.PluginID == pluginID {
			return assignment, true
		}
	}

	return nil, false
}
