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
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/hashutil"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
	"github.com/tetratelabs/wazero/sys"
)

const (
	pluginHostModule         = "env"
	pluginDefaultInterval    = 60 * time.Second
	pluginDefaultTimeout     = 10 * time.Second
	pluginMaxPayloadBytes    = 2 * 1024 * 1024
	pluginMaxWasmBytes       = 64 * 1024 * 1024
	pluginMaxHTTPBodyBytes   = 2 * 1024 * 1024
	pluginDefaultHTTPTimeout = 15 * time.Second
	pluginWarmupGrace        = 2 * time.Minute
)

const (
	pluginErrOK        int32 = 0
	pluginErrInvalid   int32 = -1
	pluginErrDenied    int32 = -2
	pluginErrTooLarge  int32 = -3
	pluginErrNotFound  int32 = -4
	pluginErrInternal  int32 = -5
	pluginErrTimeout   int32 = -6
	pluginErrBadHandle int32 = -7
)

var (
	errPluginWasmUnavailable = errors.New("plugin wasm unavailable")
	errEntrypointNotFound    = errors.New("entrypoint not found")
	errDownloadFailed        = errors.New("download failed")
	errDownloadTooLarge      = errors.New("download too large")
	errContentHashMismatch   = errors.New("content hash mismatch")
	errInvalidPath           = errors.New("invalid path")
)

// PluginManagerConfig configures the Wasm plugin manager.
type PluginManagerConfig struct {
	CacheDir      string
	LocalStoreDir string
	Logger        logger.Logger
	HTTPClient    *http.Client
}

// PluginManager manages Wasm plugin assignments and execution.
type PluginManager struct {
	logger        logger.Logger
	cacheDir      string
	localStoreDir string
	httpClient    *http.Client

	ctx    context.Context
	cancel context.CancelFunc

	mu      sync.RWMutex
	runners map[string]*pluginRunner
	results chan PluginResult

	stateMu  sync.Mutex
	states   map[string]*assignmentState
	stateNow func() time.Time

	limitsMu         sync.Mutex
	limits           pluginEngineLimits
	concurrentActive int
	openConnections  int

	statsMu sync.Mutex
	stats   pluginEngineStats

	configMu      sync.Mutex
	lastConfigSHA string
}

type assignmentState struct {
	firstSeen time.Time
	ready     bool
}

// PluginResult captures a raw plugin result payload.
type PluginResult struct {
	AssignmentID string
	PluginID     string
	PluginName   string
	Payload      []byte
	ObservedAt   time.Time
}

type pluginEngineStats struct {
	assignmentsTotal     int
	assignmentsAdmitted  int
	assignmentsRejected  int
	requestedMemoryMB    int
	requestedCPUMS       int
	requestedConnections int
	lastConfigAt         time.Time
	execTotal            int64
	execFailures         int64
	lastExecAt           time.Time
	lastFailureAt        time.Time
}

type PluginEngineSnapshot struct {
	ObservedAt           time.Time
	Limits               pluginEngineLimits
	RequestedMemoryMB    int
	RequestedCPUMS       int
	RequestedConnections int
	AssignmentsTotal     int
	AssignmentsAdmitted  int
	AssignmentsRejected  int
	ActiveExecutions     int
	OpenConnections      int
	ExecTotal            int64
	ExecFailures         int64
	LastExecAt           time.Time
	LastFailureAt        time.Time
	LastConfigAt         time.Time
}

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

	return &PluginManager{
		logger:        cfg.Logger,
		cacheDir:      cacheDir,
		localStoreDir: localStoreDir,
		httpClient:    client,
		ctx:           rootCtx,
		cancel:        cancel,
		runners:       make(map[string]*pluginRunner),
		results:       make(chan PluginResult, 1024),
		states:        make(map[string]*assignmentState),
		stateNow:      time.Now,
	}
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
		m.logger.Debug().Str("config_hash", configHash).Msg("Plugin config unchanged; skipping apply")
		return
	}

	admitted, rejected, usage := m.admitAssignments(assignments, limits)
	m.updateConfigStats(len(assignments), len(admitted), len(rejected), usage)

	m.refreshAssignmentStates(admitted)

	m.mu.Lock()
	prev := m.runners
	m.runners = make(map[string]*pluginRunner)
	m.mu.Unlock()

	for _, runner := range prev {
		runner.stop()
	}

	for _, assignment := range rejected {
		m.enqueueResult(buildPluginErrorResult(assignment, "admission denied: engine limits exceeded"))
	}

	for _, assignment := range admitted {
		runner := newPluginRunner(m, assignment)
		m.mu.Lock()
		m.runners[assignment.AssignmentID] = runner
		m.mu.Unlock()
		runner.start(m.ctx)
		m.prefetchAssignment(assignment)
	}

	m.setConfigHash(configHash)
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

	m.mu.Lock()
	prev := m.runners
	m.runners = make(map[string]*pluginRunner)
	m.mu.Unlock()

	for _, runner := range prev {
		runner.stop()
	}
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

func (m *PluginManager) enqueueResult(result PluginResult) {
	select {
	case m.results <- result:
	default:
		m.logger.Warn().
			Str("assignment_id", result.AssignmentID).
			Msg("Plugin result dropped due to backpressure")
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
		r.manager.enqueueResult(buildPluginErrorResult(r.assignment, "admission denied: max concurrent reached"))
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
		r.manager.enqueueResult(buildPluginErrorResult(r.assignment, fmt.Sprintf("execution failed: %s", err)))
		r.manager.logger.Warn().
			Err(err).
			Str("assignment_id", r.assignment.AssignmentID).
			Msg("Plugin execution failed")
		return
	}

	if err := r.manager.executeWithWasm(runCtx, r.assignment, wasm); err != nil {
		r.manager.recordExecution(false)
		r.manager.enqueueResult(buildPluginErrorResult(r.assignment, fmt.Sprintf("execution failed: %s", err)))
		r.manager.logger.Warn().
			Err(err).
			Str("assignment_id", r.assignment.AssignmentID).
			Msg("Plugin execution failed")
		return
	}

	r.manager.recordExecution(true)
}

type pluginAssignment struct {
	AssignmentID string
	PluginID     string
	PackageID    string
	Version      string
	Name         string
	Entrypoint   string
	Runtime      string
	Outputs      string
	Capabilities map[string]bool
	ParamsJSON   []byte
	Permissions  pluginPermissions
	Resources    pluginResources
	Interval     time.Duration
	Timeout      time.Duration
	WasmObject   string
	ContentHash  string
	DownloadURL  string
}

type pluginPermissions struct {
	AllowedDomains  []string `json:"allowed_domains"`
	AllowedNetworks []string `json:"allowed_networks"`
	AllowedPorts    []int    `json:"allowed_ports"`

	allowedDomainSet map[string]struct{}
	allowedPrefixes  []netip.Prefix
	allowedPortSet   map[int]struct{}
}

type pluginResources struct {
	RequestedMemoryMB  int `json:"requested_memory_mb"`
	RequestedCPUMS     int `json:"requested_cpu_ms"`
	MaxOpenConnections int `json:"max_open_connections"`
}

type pluginEngineLimits struct {
	MaxMemoryMB        int
	MaxCPUMS           int
	MaxConcurrent      int
	MaxOpenConnections int
}

type pluginConfigFingerprint struct {
	Limits      pluginEngineLimits            `json:"limits"`
	Assignments []pluginAssignmentFingerprint `json:"assignments"`
}

type pluginAssignmentFingerprint struct {
	AssignmentID string                       `json:"assignment_id"`
	PluginID     string                       `json:"plugin_id"`
	PackageID    string                       `json:"package_id"`
	Version      string                       `json:"version"`
	Name         string                       `json:"name"`
	Entrypoint   string                       `json:"entrypoint"`
	Runtime      string                       `json:"runtime"`
	Outputs      string                       `json:"outputs"`
	Capabilities []string                     `json:"capabilities"`
	ParamsBase64 string                       `json:"params_base64"`
	Permissions  pluginPermissionsFingerprint `json:"permissions"`
	Resources    pluginResources              `json:"resources"`
	IntervalSec  int64                        `json:"interval_sec"`
	TimeoutSec   int64                        `json:"timeout_sec"`
	WasmObject   string                       `json:"wasm_object"`
	ContentHash  string                       `json:"content_hash"`
}

type pluginPermissionsFingerprint struct {
	AllowedDomains  []string `json:"allowed_domains"`
	AllowedNetworks []string `json:"allowed_networks"`
	AllowedPorts    []int    `json:"allowed_ports"`
}

func engineLimitsFromProto(cfg *proto.PluginConfig) pluginEngineLimits {
	if cfg == nil || cfg.EngineLimits == nil {
		return pluginEngineLimits{}
	}

	limits := cfg.EngineLimits
	return pluginEngineLimits{
		MaxMemoryMB:        int(limits.MaxMemoryMb),
		MaxCPUMS:           int(limits.MaxCpuMs),
		MaxConcurrent:      int(limits.MaxConcurrent),
		MaxOpenConnections: int(limits.MaxOpenConnections),
	}
}

func buildPluginConfigHash(limits pluginEngineLimits, assignments []*pluginAssignment) string {
	fingerprint := pluginConfigFingerprint{
		Limits:      limits,
		Assignments: make([]pluginAssignmentFingerprint, 0, len(assignments)),
	}

	for _, assignment := range assignments {
		if assignment == nil {
			continue
		}
		fingerprint.Assignments = append(
			fingerprint.Assignments,
			buildAssignmentFingerprint(assignment),
		)
	}

	sort.Slice(fingerprint.Assignments, func(i, j int) bool {
		return fingerprint.Assignments[i].AssignmentID < fingerprint.Assignments[j].AssignmentID
	})

	data, err := json.Marshal(fingerprint)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func buildAssignmentFingerprint(assignment *pluginAssignment) pluginAssignmentFingerprint {
	capabilities := make([]string, 0, len(assignment.Capabilities))
	for cap := range assignment.Capabilities {
		capabilities = append(capabilities, cap)
	}
	sort.Strings(capabilities)

	allowedDomains := append([]string(nil), assignment.Permissions.AllowedDomains...)
	allowedNetworks := append([]string(nil), assignment.Permissions.AllowedNetworks...)
	allowedPorts := append([]int(nil), assignment.Permissions.AllowedPorts...)
	sort.Strings(allowedDomains)
	sort.Strings(allowedNetworks)
	sort.Ints(allowedPorts)

	params := ""
	if len(assignment.ParamsJSON) > 0 {
		params = base64.StdEncoding.EncodeToString(assignment.ParamsJSON)
	}

	return pluginAssignmentFingerprint{
		AssignmentID: assignment.AssignmentID,
		PluginID:     assignment.PluginID,
		PackageID:    assignment.PackageID,
		Version:      assignment.Version,
		Name:         assignment.Name,
		Entrypoint:   assignment.Entrypoint,
		Runtime:      assignment.Runtime,
		Outputs:      assignment.Outputs,
		Capabilities: capabilities,
		ParamsBase64: params,
		Permissions: pluginPermissionsFingerprint{
			AllowedDomains:  allowedDomains,
			AllowedNetworks: allowedNetworks,
			AllowedPorts:    allowedPorts,
		},
		Resources:   assignment.Resources,
		IntervalSec: int64(assignment.Interval / time.Second),
		TimeoutSec:  int64(assignment.Timeout / time.Second),
		WasmObject:  assignment.WasmObject,
		ContentHash: assignment.ContentHash,
	}
}

func newPluginAssignment(cfg *proto.PluginAssignmentConfig, log logger.Logger) *pluginAssignment {
	assignment := &pluginAssignment{
		AssignmentID: cfg.AssignmentId,
		PluginID:     cfg.PluginId,
		PackageID:    cfg.PackageId,
		Version:      cfg.Version,
		Name:         cfg.Name,
		Entrypoint:   cfg.Entrypoint,
		Runtime:      cfg.Runtime,
		Outputs:      cfg.Outputs,
		Capabilities: make(map[string]bool),
		ParamsJSON:   cfg.ParamsJson,
		Interval:     time.Duration(cfg.IntervalSec) * time.Second,
		Timeout:      time.Duration(cfg.TimeoutSec) * time.Second,
		WasmObject:   strings.TrimSpace(cfg.WasmObjectKey),
		ContentHash:  strings.TrimSpace(cfg.ContentHash),
		DownloadURL:  strings.TrimSpace(cfg.DownloadUrl),
	}

	for _, cap := range cfg.Capabilities {
		clean := strings.TrimSpace(cap)
		if clean == "" {
			continue
		}
		assignment.Capabilities[clean] = true
	}

	if len(cfg.PermissionsJson) > 0 {
		if err := json.Unmarshal(cfg.PermissionsJson, &assignment.Permissions); err != nil {
			log.Warn().Err(err).Str("assignment_id", assignment.AssignmentID).Msg("Invalid plugin permissions JSON")
		}
	}

	if len(cfg.ResourcesJson) > 0 {
		if err := json.Unmarshal(cfg.ResourcesJson, &assignment.Resources); err != nil {
			log.Warn().Err(err).Str("assignment_id", assignment.AssignmentID).Msg("Invalid plugin resources JSON")
		}
	}

	assignment.Permissions.normalize()
	assignment.ContentHash = normalizeContentHash(assignment.ContentHash, log, assignment.AssignmentID)

	if assignment.Interval <= 0 {
		assignment.Interval = pluginDefaultInterval
	}
	if assignment.Timeout <= 0 {
		assignment.Timeout = pluginDefaultTimeout
	}

	return assignment
}

func normalizeContentHash(hash string, log logger.Logger, assignmentID string) string {
	if hash == "" {
		return ""
	}
	canonical, err := hashutil.CanonicalHexSHA256(hash)
	if err != nil {
		log.Warn().Err(err).Str("assignment_id", assignmentID).Msg("Invalid content hash")
		return ""
	}
	return canonical
}

func (p *pluginPermissions) normalize() {
	p.allowedDomainSet = make(map[string]struct{})
	for _, domain := range p.AllowedDomains {
		trimmed := strings.ToLower(strings.TrimSpace(domain))
		if trimmed == "" {
			continue
		}
		p.allowedDomainSet[trimmed] = struct{}{}
	}

	p.allowedPortSet = make(map[int]struct{})
	for _, port := range p.AllowedPorts {
		if port <= 0 {
			continue
		}
		p.allowedPortSet[port] = struct{}{}
	}

	p.allowedPrefixes = p.allowedPrefixes[:0]
	for _, network := range p.AllowedNetworks {
		trimmed := strings.TrimSpace(network)
		if trimmed == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(trimmed)
		if err != nil {
			continue
		}
		p.allowedPrefixes = append(p.allowedPrefixes, prefix)
	}
}

func (p *pluginPermissions) allowsDomain(host string) bool {
	if len(p.allowedDomainSet) == 0 {
		return false
	}

	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "" {
		return false
	}

	if _, ok := p.allowedDomainSet["*"]; ok {
		return true
	}

	if _, ok := p.allowedDomainSet[host]; ok {
		return true
	}

	for entry := range p.allowedDomainSet {
		if strings.HasPrefix(entry, "*.") {
			base := strings.TrimPrefix(entry, "*.")
			if host == base || strings.HasSuffix(host, "."+base) {
				return true
			}
		}
	}

	return false
}

func (p *pluginPermissions) allowsPort(port int) bool {
	if len(p.allowedPortSet) == 0 {
		return true
	}
	_, ok := p.allowedPortSet[port]
	return ok
}

func (p *pluginPermissions) allowsAddress(addr netip.Addr) bool {
	if len(p.allowedPrefixes) == 0 {
		return false
	}
	for _, prefix := range p.allowedPrefixes {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

func (m *PluginManager) executeWithWasm(ctx context.Context, assignment *pluginAssignment, wasm []byte) error {
	memPages := memoryPages(assignment.Resources.RequestedMemoryMB)
	runtimeCfg := wazero.NewRuntimeConfig()
	if memPages > 0 {
		runtimeCfg = runtimeCfg.WithMemoryLimitPages(memPages)
	}

	runtime := wazero.NewRuntimeWithConfig(ctx, runtimeCfg)
	defer func() {
		_ = runtime.Close(ctx)
	}()

	exec := newPluginExecution(m, assignment)
	if err := exec.instantiateHostModule(ctx, runtime); err != nil {
		return err
	}

	// Always instantiate WASI - it's harmless if unused but required if the
	// plugin imports from wasi_snapshot_preview1. Many WASM toolchains
	// (TinyGo, Rust, etc.) automatically include WASI imports.
	wasi, err := wasi_snapshot_preview1.Instantiate(ctx, runtime)
	if err != nil {
		return fmt.Errorf("instantiate wasi: %w", err)
	}
	defer func() {
		_ = wasi.Close(ctx)
	}()

	// Configure walltime and nanotime on the plugin module so WASI clock
	// functions work correctly. WASI functions use the sys.Context from
	// the calling module (our plugin), not from the WASI module itself.
	//
	// IMPORTANT: Use WithStartFunctions() with NO arguments to prevent _start
	// from being called automatically. TinyGo's _start calls proc_exit(0) which
	// closes the module and clears the Sys field, preventing subsequent WASI
	// clock functions from working.
	modConfig := wazero.NewModuleConfig().
		WithName(assignment.AssignmentID).
		WithSysWalltime().
		WithSysNanotime().
		WithSysNanosleep().
		WithStartFunctions()

	module, err := runtime.InstantiateWithConfig(ctx, wasm, modConfig)
	if err != nil {
		return fmt.Errorf("instantiate module: %w", err)
	}
	defer func() {
		_ = module.Close(ctx)
	}()

	entrypoint := module.ExportedFunction(assignment.Entrypoint)
	if entrypoint == nil {
		return fmt.Errorf("%w: %s", errEntrypointNotFound, assignment.Entrypoint)
	}

	if _, err := entrypoint.Call(ctx); err != nil {
		switch {
		case isExitCodeZero(err):
			// Treat a zero exit code as a clean completion (WASI proc_exit(0)).
		case exec.hasSubmitted():
			m.logger.Warn().
				Err(err).
				Str("assignment_id", assignment.AssignmentID).
				Msg("Plugin exited after submitting result")
		default:
			return fmt.Errorf("entrypoint failed: %w", err)
		}
	}

	if !exec.hasSubmitted() {
		m.enqueueResult(buildPluginErrorResult(assignment, "no result submitted"))
	}

	exec.closeAll()

	return nil
}

func isExitCodeZero(err error) bool {
	var exitErr *sys.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode() == 0
	}
	return false
}

func memoryPages(requestedMB int) uint32 {
	if requestedMB <= 0 {
		return 0
	}
	bytes := int64(requestedMB) * 1024 * 1024
	pages := bytes / (64 * 1024)
	if bytes%(64*1024) != 0 {
		pages++
	}
	if pages < 1 {
		pages = 1
	}
	if pages > int64(^uint32(0)) {
		return ^uint32(0)
	}
	return uint32(pages)
}

func (m *PluginManager) loadWasm(ctx context.Context, assignment *pluginAssignment) ([]byte, error) {
	cachePath := m.cachePath(assignment)
	if cachePath != "" {
		if data, err := os.ReadFile(cachePath); err == nil {
			if err := verifyContentHash(data, assignment.ContentHash); err == nil {
				m.markAssignmentReady(assignment.AssignmentID)
				return data, nil
			}
			_ = os.Remove(cachePath)
		}
	}

	if assignment.DownloadURL != "" {
		data, err := m.downloadWasm(ctx, assignment.DownloadURL)
		if err != nil {
			return nil, err
		}
		if err := verifyContentHash(data, assignment.ContentHash); err != nil {
			return nil, err
		}
		m.persistCache(cachePath, data)
		m.markAssignmentReady(assignment.AssignmentID)
		return data, nil
	}

	if assignment.WasmObject != "" {
		if localPath, err := safeJoin(m.localStoreDir, assignment.WasmObject); err == nil {
			if data, err := os.ReadFile(localPath); err == nil {
				if err := verifyContentHash(data, assignment.ContentHash); err != nil {
					return nil, err
				}
				m.persistCache(cachePath, data)
				m.markAssignmentReady(assignment.AssignmentID)
				return data, nil
			}
		}
	}

	return nil, errPluginWasmUnavailable
}

func (m *PluginManager) refreshAssignmentStates(assignments []*pluginAssignment) {
	now := m.stateNow()
	states := make(map[string]*assignmentState, len(assignments))

	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	for _, assignment := range assignments {
		state := m.states[assignment.AssignmentID]
		if state == nil {
			state = &assignmentState{firstSeen: now}
		}
		if !state.ready && m.cacheExists(assignment) {
			state.ready = true
		}
		states[assignment.AssignmentID] = state
	}

	m.states = states
}

func (m *PluginManager) cacheExists(assignment *pluginAssignment) bool {
	cachePath := m.cachePath(assignment)
	if cachePath == "" {
		return false
	}
	_, err := os.Stat(cachePath)
	return err == nil
}

func (m *PluginManager) markAssignmentReady(assignmentID string) {
	if assignmentID == "" {
		return
	}
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	state := m.states[assignmentID]
	if state == nil {
		state = &assignmentState{firstSeen: m.stateNow()}
		m.states[assignmentID] = state
	}
	state.ready = true
}

func (m *PluginManager) assignmentState(assignmentID string) *assignmentState {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	state := m.states[assignmentID]
	if state == nil {
		state = &assignmentState{firstSeen: m.stateNow()}
		m.states[assignmentID] = state
	}
	return state
}

func (m *PluginManager) shouldSkipWarmup(assignment *pluginAssignment) bool {
	state := m.assignmentState(assignment.AssignmentID)
	if state.ready {
		return false
	}
	return time.Since(state.firstSeen) < pluginWarmupGrace
}

func (m *PluginManager) prefetchAssignment(assignment *pluginAssignment) {
	if assignment == nil || assignment.DownloadURL == "" {
		return
	}

	if state := m.assignmentState(assignment.AssignmentID); state.ready {
		return
	}

	go func() {
		ctx, cancel := context.WithTimeout(m.ctx, pluginDefaultHTTPTimeout*2)
		defer cancel()
		if _, err := m.loadWasm(ctx, assignment); err != nil && !errors.Is(err, errPluginWasmUnavailable) {
			m.logger.Warn().
				Err(err).
				Str("assignment_id", assignment.AssignmentID).
				Msg("Plugin wasm prefetch failed")
		}
	}()
}

func (m *PluginManager) cachePath(assignment *pluginAssignment) string {
	key := assignment.ContentHash
	if key == "" {
		key = assignment.PackageID
	}
	if key == "" {
		key = assignment.AssignmentID
	}
	if key == "" {
		return ""
	}
	return filepath.Join(m.cacheDir, key+".wasm")
}

func (m *PluginManager) persistCache(path string, data []byte) {
	if path == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	_ = os.WriteFile(path, data, 0o640)
}

func (m *PluginManager) downloadWasm(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	resp, err := m.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: status %d", errDownloadFailed, resp.StatusCode)
	}

	limited := io.LimitReader(resp.Body, pluginMaxWasmBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > pluginMaxWasmBytes {
		return nil, fmt.Errorf("%w: %d bytes", errDownloadTooLarge, pluginMaxWasmBytes)
	}
	return data, nil
}

func verifyContentHash(data []byte, expected string) error {
	if expected == "" {
		return nil
	}
	sum := sha256.Sum256(data)
	if !hashutil.EqualSHA256(expected, sum) {
		return errContentHashMismatch
	}
	return nil
}

func safeJoin(base, target string) (string, error) {
	clean := filepath.Clean(strings.TrimSpace(target))
	if clean == "" || clean == "." {
		return "", errInvalidPath
	}
	if filepath.IsAbs(clean) || strings.HasPrefix(clean, "..") {
		return "", errInvalidPath
	}
	return filepath.Join(base, clean), nil
}

type pluginExecution struct {
	manager    *PluginManager
	assignment *pluginAssignment
	mu         sync.Mutex
	conns      map[uint32]net.Conn
	nextHandle uint32
	submitted  bool
}

func newPluginExecution(manager *PluginManager, assignment *pluginAssignment) *pluginExecution {
	return &pluginExecution{
		manager:    manager,
		assignment: assignment,
		conns:      make(map[uint32]net.Conn),
		nextHandle: 1,
	}
}

func (e *pluginExecution) instantiateHostModule(ctx context.Context, runtime wazero.Runtime) error {
	builder := runtime.NewHostModuleBuilder(pluginHostModule)

	builder.NewFunctionBuilder().
		WithFunc(e.hostGetConfig).
		Export("get_config")
	builder.NewFunctionBuilder().
		WithFunc(e.hostLog).
		Export("log")
	builder.NewFunctionBuilder().
		WithFunc(e.hostSubmitResult).
		Export("submit_result")
	builder.NewFunctionBuilder().
		WithFunc(e.hostHTTPRequest).
		Export("http_request")
	builder.NewFunctionBuilder().
		WithFunc(e.hostTCPConnect).
		Export("tcp_connect")
	builder.NewFunctionBuilder().
		WithFunc(e.hostTCPRead).
		Export("tcp_read")
	builder.NewFunctionBuilder().
		WithFunc(e.hostTCPWrite).
		Export("tcp_write")
	builder.NewFunctionBuilder().
		WithFunc(e.hostTCPClose).
		Export("tcp_close")
	builder.NewFunctionBuilder().
		WithFunc(e.hostUDPSendTo).
		Export("udp_sendto")

	_, err := builder.Instantiate(ctx)
	return err
}

func (e *pluginExecution) hostGetConfig(_ context.Context, mod api.Module, ptr, size uint32) int32 {
	if !e.hasCapability("get_config") {
		return pluginErrDenied
	}

	payload := e.assignment.ParamsJSON
	if len(payload) == 0 {
		return pluginErrOK
	}

	if len(payload) > int(size) {
		return pluginErrTooLarge
	}

	if !writeMemory(mod, ptr, payload) {
		return pluginErrInvalid
	}

	return int32(len(payload))
}

func (e *pluginExecution) hostLog(_ context.Context, mod api.Module, level uint32, ptr, size uint32) {
	if !e.hasCapability("log") {
		return
	}

	msg, ok := readMemory(mod, ptr, size)
	if !ok {
		return
	}
	if len(msg) > pluginMaxPayloadBytes {
		msg = msg[:pluginMaxPayloadBytes]
	}
	text := strings.TrimSpace(string(msg))
	if text == "" {
		return
	}

	switch level {
	case 0:
		e.manager.logger.Debug().Str("assignment_id", e.assignment.AssignmentID).Msg(text)
	case 1:
		e.manager.logger.Info().Str("assignment_id", e.assignment.AssignmentID).Msg(text)
	case 2:
		e.manager.logger.Warn().Str("assignment_id", e.assignment.AssignmentID).Msg(text)
	default:
		e.manager.logger.Error().Str("assignment_id", e.assignment.AssignmentID).Msg(text)
	}
}

func (e *pluginExecution) hostSubmitResult(_ context.Context, mod api.Module, ptr, size uint32) int32 {
	if !e.hasCapability("submit_result") {
		return pluginErrDenied
	}

	if size == 0 {
		return pluginErrInvalid
	}

	payload, ok := readMemory(mod, ptr, size)
	if !ok {
		return pluginErrInvalid
	}
	if len(payload) > pluginMaxPayloadBytes {
		return pluginErrTooLarge
	}

	e.manager.enqueueResult(PluginResult{
		AssignmentID: e.assignment.AssignmentID,
		PluginID:     e.assignment.PluginID,
		PluginName:   e.assignment.Name,
		Payload:      payload,
		ObservedAt:   time.Now().UTC(),
	})
	e.markSubmitted()

	return pluginErrOK
}

type httpRequestPayload struct {
	Method     string            `json:"method"`
	URL        string            `json:"url"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body"`
	BodyBase64 string            `json:"body_base64"`
	TimeoutMS  int               `json:"timeout_ms"`
}

type httpResponsePayload struct {
	Status       int               `json:"status"`
	Headers      map[string]string `json:"headers,omitempty"`
	BodyBase64   string            `json:"body_base64"`
	BodyEncoding string            `json:"body_encoding,omitempty"`
}

func (e *pluginExecution) hostHTTPRequest(ctx context.Context, mod api.Module, reqPtr, reqLen, respPtr, respLen uint32) int32 {
	if !e.hasCapability("http_request") {
		return pluginErrDenied
	}

	reqBytes, ok := readMemory(mod, reqPtr, reqLen)
	if !ok {
		return pluginErrInvalid
	}
	if len(reqBytes) > pluginMaxPayloadBytes {
		return pluginErrTooLarge
	}

	var payload httpRequestPayload
	if err := json.Unmarshal(reqBytes, &payload); err != nil {
		return pluginErrInvalid
	}

	reqURL, err := url.Parse(strings.TrimSpace(payload.URL))
	if err != nil || reqURL.Host == "" {
		return pluginErrInvalid
	}

	host := reqURL.Hostname()
	if !e.assignment.Permissions.allowsDomain(host) {
		return pluginErrDenied
	}

	method := strings.ToUpper(strings.TrimSpace(payload.Method))
	if method == "" {
		method = http.MethodGet
	}

	body, err := decodeBody(payload)
	if err != nil {
		return pluginErrInvalid
	}

	timeout := pluginDefaultHTTPTimeout
	if payload.TimeoutMS > 0 {
		timeout = time.Duration(payload.TimeoutMS) * time.Millisecond
	}

	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	httpReq, err := http.NewRequestWithContext(reqCtx, method, reqURL.String(), bytes.NewReader(body))
	if err != nil {
		return pluginErrInvalid
	}

	for key, value := range payload.Headers {
		if strings.TrimSpace(key) == "" {
			continue
		}
		httpReq.Header.Set(key, value)
	}

	resp, err := e.manager.httpClient.Do(httpReq)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return pluginErrTimeout
		}
		return pluginErrInternal
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	limited := io.LimitReader(resp.Body, pluginMaxHTTPBodyBytes+1)
	bodyBytes, err := io.ReadAll(limited)
	if err != nil {
		return pluginErrInternal
	}
	if int64(len(bodyBytes)) > pluginMaxHTTPBodyBytes {
		return pluginErrTooLarge
	}

	responsePayload := httpResponsePayload{
		Status:       resp.StatusCode,
		Headers:      flattenHeaders(resp.Header),
		BodyBase64:   base64.StdEncoding.EncodeToString(bodyBytes),
		BodyEncoding: "base64",
	}

	responseBytes, err := json.Marshal(responsePayload)
	if err != nil {
		return pluginErrInternal
	}
	if len(responseBytes) > int(respLen) {
		return pluginErrTooLarge
	}

	if !writeMemory(mod, respPtr, responseBytes) {
		return pluginErrInvalid
	}

	return int32(len(responseBytes))
}

func decodeBody(payload httpRequestPayload) ([]byte, error) {
	if payload.BodyBase64 != "" {
		return base64.StdEncoding.DecodeString(payload.BodyBase64)
	}
	if payload.Body != "" {
		return []byte(payload.Body), nil
	}
	return nil, nil
}

func flattenHeaders(headers http.Header) map[string]string {
	if len(headers) == 0 {
		return nil
	}

	flat := make(map[string]string, len(headers))
	for key, values := range headers {
		if len(values) == 0 {
			continue
		}
		flat[key] = strings.Join(values, ",")
	}
	return flat
}

func (e *pluginExecution) hostTCPConnect(ctx context.Context, mod api.Module, addrPtr, addrLen, port, timeoutMS uint32) int32 {
	if !e.hasCapability("tcp_connect") {
		return pluginErrDenied
	}

	addrBytes, ok := readMemory(mod, addrPtr, addrLen)
	if !ok {
		return pluginErrInvalid
	}
	host := strings.TrimSpace(string(addrBytes))
	if host == "" {
		return pluginErrInvalid
	}

	if !e.assignment.Permissions.allowsPort(int(port)) {
		return pluginErrDenied
	}

	ip, allowed := e.resolveAllowedAddr(ctx, host)
	if !allowed {
		return pluginErrDenied
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}

	dialer := net.Dialer{Timeout: timeout}
	conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(ip.String(), fmt.Sprintf("%d", port)))
	if err != nil {
		return pluginErrInternal
	}

	handle := e.storeConn(conn)
	if handle == 0 {
		_ = conn.Close()
		return pluginErrTooLarge
	}

	return int32(handle)
}

func (e *pluginExecution) hostTCPRead(_ context.Context, mod api.Module, handle, bufPtr, bufLen, timeoutMS uint32) int32 {
	if !e.hasCapability("tcp_read") {
		return pluginErrDenied
	}

	conn := e.getConn(handle)
	if conn == nil {
		return pluginErrBadHandle
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}
	_ = conn.SetReadDeadline(time.Now().Add(timeout))

	if bufLen == 0 {
		return pluginErrInvalid
	}

	readBuf := make([]byte, bufLen)
	n, err := conn.Read(readBuf)
	if err != nil && !errors.Is(err, io.EOF) {
		return pluginErrInternal
	}

	if n == 0 {
		return pluginErrOK
	}

	if !writeMemory(mod, bufPtr, readBuf[:n]) {
		return pluginErrInvalid
	}

	return int32(n)
}

func (e *pluginExecution) hostTCPWrite(_ context.Context, mod api.Module, handle, bufPtr, bufLen, timeoutMS uint32) int32 {
	if !e.hasCapability("tcp_write") {
		return pluginErrDenied
	}

	conn := e.getConn(handle)
	if conn == nil {
		return pluginErrBadHandle
	}

	data, ok := readMemory(mod, bufPtr, bufLen)
	if !ok {
		return pluginErrInvalid
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}
	_ = conn.SetWriteDeadline(time.Now().Add(timeout))

	n, err := conn.Write(data)
	if err != nil {
		return pluginErrInternal
	}
	return int32(n)
}

func (e *pluginExecution) hostTCPClose(_ context.Context, _ api.Module, handle uint32) int32 {
	if !e.hasCapability("tcp_close") {
		return pluginErrDenied
	}

	conn := e.deleteConn(handle)
	if conn == nil {
		return pluginErrBadHandle
	}
	_ = conn.Close()
	return pluginErrOK
}

func (e *pluginExecution) hostUDPSendTo(ctx context.Context, mod api.Module, addrPtr, addrLen, port, bufPtr, bufLen, timeoutMS uint32) int32 {
	if !e.hasCapability("udp_sendto") {
		return pluginErrDenied
	}

	addrBytes, ok := readMemory(mod, addrPtr, addrLen)
	if !ok {
		return pluginErrInvalid
	}
	host := strings.TrimSpace(string(addrBytes))
	if host == "" {
		return pluginErrInvalid
	}

	if !e.assignment.Permissions.allowsPort(int(port)) {
		return pluginErrDenied
	}

	ip, allowed := e.resolveAllowedAddr(ctx, host)
	if !allowed {
		return pluginErrDenied
	}

	payload, ok := readMemory(mod, bufPtr, bufLen)
	if !ok {
		return pluginErrInvalid
	}

	raddr := &net.UDPAddr{IP: net.ParseIP(ip.String()), Port: int(port)}
	conn, err := net.DialUDP("udp", nil, raddr)
	if err != nil {
		return pluginErrInternal
	}
	defer func() {
		_ = conn.Close()
	}()

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}
	_ = conn.SetWriteDeadline(time.Now().Add(timeout))

	n, err := conn.Write(payload)
	if err != nil {
		return pluginErrInternal
	}

	return int32(n)
}

func (e *pluginExecution) hasCapability(capability string) bool {
	if e.assignment.Capabilities == nil {
		return false
	}
	return e.assignment.Capabilities[capability]
}

func (e *pluginExecution) resolveAllowedAddr(ctx context.Context, host string) (netip.Addr, bool) {
	addr, err := netip.ParseAddr(host)
	if err == nil {
		return addr, e.assignment.Permissions.allowsAddress(addr)
	}

	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil || len(addrs) == 0 {
		return netip.Addr{}, false
	}

	for _, candidate := range addrs {
		if addr, ok := netip.AddrFromSlice(candidate.IP); ok {
			if e.assignment.Permissions.allowsAddress(addr) {
				return addr, true
			}
		}
	}

	return netip.Addr{}, false
}

func (e *pluginExecution) storeConn(conn net.Conn) uint32 {
	e.mu.Lock()
	defer e.mu.Unlock()

	max := e.assignment.Resources.MaxOpenConnections
	if max > 0 && len(e.conns) >= max {
		return 0
	}

	if !e.manager.reserveConnection() {
		return 0
	}

	handle := e.nextHandle
	e.nextHandle++
	e.conns[handle] = conn
	return handle
}

func (e *pluginExecution) getConn(handle uint32) net.Conn {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.conns[handle]
}

func (e *pluginExecution) deleteConn(handle uint32) net.Conn {
	e.mu.Lock()
	defer e.mu.Unlock()
	conn := e.conns[handle]
	delete(e.conns, handle)
	if conn != nil {
		e.manager.releaseConnection()
	}
	return conn
}

func (e *pluginExecution) closeAll() {
	e.mu.Lock()
	defer e.mu.Unlock()
	for handle, conn := range e.conns {
		_ = conn.Close()
		delete(e.conns, handle)
		e.manager.releaseConnection()
	}
}

func (e *pluginExecution) markSubmitted() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.submitted = true
}

func (e *pluginExecution) hasSubmitted() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.submitted
}

func readMemory(mod api.Module, ptr, size uint32) ([]byte, bool) {
	mem := mod.Memory()
	if mem == nil {
		return nil, false
	}
	data, ok := mem.Read(ptr, size)
	if !ok {
		return nil, false
	}
	out := make([]byte, len(data))
	copy(out, data)
	return out, true
}

func writeMemory(mod api.Module, ptr uint32, data []byte) bool {
	mem := mod.Memory()
	if mem == nil {
		return false
	}
	return mem.Write(ptr, data)
}
