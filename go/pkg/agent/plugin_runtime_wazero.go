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
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/hashutil"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
	"github.com/tetratelabs/wazero/sys"
)

func (m *PluginManager) executeWithWasm(ctx context.Context, assignment *pluginAssignment, module pluginModule) error {
	runtime := wazero.NewRuntimeWithConfig(ctx, m.newRuntimeConfig(assignment.Resources.RequestedMemoryMB))
	defer func() {
		_ = runtime.Close(ctx)
	}()

	exec := newPluginExecution(m, assignment)
	defer exec.closeAll()
	exec.moduleContentHash = module.contentHash
	exec.applyRunOverrides(time.Now())

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

	instance, err := runtime.InstantiateWithConfig(ctx, module.wasm, modConfig)
	if err != nil {
		return fmt.Errorf("instantiate module: %w", err)
	}
	defer func() {
		_ = instance.Close(ctx)
	}()

	entrypoint := instance.ExportedFunction(assignment.Entrypoint)
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
		m.tryEnqueueResult(buildPluginErrorResult(assignment, module.contentHash, "no result submitted"))
	}

	return nil
}

func (m *PluginManager) executeActionWithWasm(
	ctx context.Context,
	assignment *pluginAssignment,
	entrypointName string,
	wasm []byte,
	configJSON []byte,
	credentialGrants []credentialBrokerGrant,
	authorizedRequestBody []byte,
	awxCallbackCredential *awxCallbackCredentialMemoryInput,
) ([]byte, error) {
	runtime := wazero.NewRuntimeWithConfig(ctx, m.newRuntimeConfig(assignment.Resources.RequestedMemoryMB))
	defer func() {
		_ = runtime.Close(ctx)
	}()

	exec := newPluginExecution(m, assignment)
	defer exec.closeAll()

	exec.mode = pluginExecutionModeAction
	exec.configJSON = configJSON
	exec.credentialGrants = credentialGrants
	exec.authorizedRequestBody = authorizedRequestBody
	exec.awxCallbackCredential = awxCallbackCredential
	defer clear(exec.authorizedRequestBody)
	if err := exec.instantiateHostModule(ctx, runtime); err != nil {
		return nil, err
	}

	wasi, err := wasi_snapshot_preview1.Instantiate(ctx, runtime)
	if err != nil {
		return nil, fmt.Errorf("instantiate wasi: %w", err)
	}
	defer func() {
		_ = wasi.Close(ctx)
	}()

	modConfig := wazero.NewModuleConfig().
		WithName(assignment.AssignmentID).
		WithSysWalltime().
		WithSysNanotime().
		WithSysNanosleep().
		WithStartFunctions()

	module, err := runtime.InstantiateWithConfig(ctx, wasm, modConfig)
	if err != nil {
		return nil, fmt.Errorf("instantiate module: %w", err)
	}
	defer func() {
		_ = module.Close(ctx)
	}()

	entrypoint := module.ExportedFunction(entrypointName)
	if entrypoint == nil {
		return nil, fmt.Errorf("%w: %s", errEntrypointNotFound, entrypointName)
	}

	if _, err := entrypoint.Call(ctx); err != nil {
		switch {
		case isExitCodeZero(err):
		case exec.hasSubmitted():
			m.logger.Warn().
				Err(err).
				Str("assignment_id", assignment.AssignmentID).
				Msg("Plugin action exited after submitting result")
		default:
			return nil, fmt.Errorf("entrypoint failed: %w", err)
		}
	}

	if !exec.hasSubmitted() {
		return nil, errPluginActionResultMissing
	}

	return exec.capturedActionResult(), nil
}

func (m *PluginManager) executeStreamingWithWasm(
	ctx context.Context,
	assignment *pluginAssignment,
	wasm []byte,
	configJSON []byte,
	bridge *pluginCameraMediaBridge,
) error {
	runtime := wazero.NewRuntimeWithConfig(ctx, m.newRuntimeConfig(assignment.Resources.RequestedMemoryMB))
	defer func() {
		_ = runtime.Close(ctx)
	}()

	exec := newPluginExecution(m, assignment)
	defer exec.closeAll()

	exec.mode = pluginExecutionModeStreaming
	exec.configJSON = configJSON
	exec.mediaBridge = bridge

	if err := exec.instantiateHostModule(ctx, runtime); err != nil {
		return err
	}

	wasi, err := wasi_snapshot_preview1.Instantiate(ctx, runtime)
	if err != nil {
		return fmt.Errorf("instantiate wasi: %w", err)
	}
	defer func() {
		_ = wasi.Close(ctx)
	}()

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
		case bridge != nil && bridge.hasOpened():
			m.logger.Info().
				Str("assignment_id", assignment.AssignmentID).
				Msg("Streaming plugin exited after opening media bridge")
		default:
			return fmt.Errorf("streaming entrypoint failed: %w", err)
		}
	}

	return nil
}

func (m *PluginManager) newRuntimeConfig(requestedMemoryMB int) wazero.RuntimeConfig {
	runtimeCfg := wazero.NewRuntimeConfig().WithCloseOnContextDone(true)
	if m != nil && m.compilationCache != nil {
		runtimeCfg = runtimeCfg.WithCompilationCache(m.compilationCache)
	}

	if memPages := memoryPages(requestedMemoryMB); memPages > 0 {
		runtimeCfg = runtimeCfg.WithMemoryLimitPages(memPages)
	}

	return runtimeCfg
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

// pluginModule is a Wasm module the host loaded and verified for one run.
// contentHash is the lowercase hex SHA-256 of wasm, computed by the host.
type pluginModule struct {
	wasm        []byte
	contentHash string
}

// loadWasm returns the assignment's verified module and records the outcome as
// the assignment's load status.
func (m *PluginManager) loadWasm(ctx context.Context, assignment *pluginAssignment) (pluginModule, error) {
	module, err := m.fetchVerifiedWasm(ctx, assignment)
	m.recordAssignmentLoad(assignment, module, err)
	return module, err
}

func (m *PluginManager) fetchVerifiedWasm(ctx context.Context, assignment *pluginAssignment) (pluginModule, error) {
	cachePath := m.cachePath(assignment)
	if cachePath != "" {
		if data, err := os.ReadFile(cachePath); err == nil {
			if module, err := verifiedPluginModule(data, assignment.ContentHash); err == nil {
				return module, nil
			}
			_ = os.Remove(cachePath)
		}
	}

	if downloadURL, _ := assignment.downloadCredentials(); downloadURL != "" {
		data, err := m.downloadWasm(ctx, assignment)
		if err != nil {
			return pluginModule{}, err
		}
		module, err := verifiedPluginModule(data, assignment.ContentHash)
		if err != nil {
			return pluginModule{}, err
		}
		m.persistCache(cachePath, data)
		return module, nil
	}

	if assignment.WasmObject != "" {
		if localPath, err := safeJoin(m.localStoreDir, assignment.WasmObject); err == nil {
			if data, err := os.ReadFile(localPath); err == nil {
				module, err := verifiedPluginModule(data, assignment.ContentHash)
				if err != nil {
					return pluginModule{}, err
				}
				m.persistCache(cachePath, data)
				return module, nil
			}
		}
	}

	return pluginModule{}, errPluginWasmUnavailable
}

// verifiedPluginModule hashes the module once, both to check it against the
// expected hash (when the assignment names one) and to stamp provenance.
func verifiedPluginModule(data []byte, expected string) (pluginModule, error) {
	sum := sha256.Sum256(data)
	if expected != "" && !hashutil.EqualSHA256(expected, sum) {
		return pluginModule{}, errContentHashMismatch
	}
	return pluginModule{wasm: data, contentHash: hex.EncodeToString(sum[:])}, nil
}

func (m *PluginManager) refreshAssignmentStates(assignments []*pluginAssignment) {
	now := m.stateNow()
	states := make(map[string]*assignmentState, len(assignments))

	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	for _, assignment := range assignments {
		state := m.states[assignment.AssignmentID]
		contentHash := assignmentStateContentHash(assignment)
		if state == nil || state.contentHash != contentHash {
			state = &assignmentState{firstSeen: now, contentHash: contentHash}
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

// recordAssignmentLoad records a module load outcome for the assignment
// generation that attempted it. A load for a superseded generation (the config
// moved on while it ran) says nothing about the current one and is dropped.
func (m *PluginManager) recordAssignmentLoad(assignment *pluginAssignment, module pluginModule, err error) {
	if assignment == nil || assignment.AssignmentID == "" {
		return
	}

	generation := assignmentStateContentHash(assignment)
	now := m.stateNow()

	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	state := m.states[assignment.AssignmentID]
	switch {
	case state == nil:
		state = &assignmentState{firstSeen: now, contentHash: generation}
		m.states[assignment.AssignmentID] = state
	case state.contentHash == "":
		state.contentHash = generation
	case state.contentHash != generation:
		return
	}

	if err != nil {
		state.load = pluginAssignmentLoad{
			status: pluginLoadStatusFailed,
			reason: pluginLoadFailureReason(err),
			at:     now,
		}
		return
	}

	state.ready = true
	state.load = pluginAssignmentLoad{
		status:      pluginLoadStatusLoaded,
		contentHash: module.contentHash,
		at:          now,
	}
}

func pluginLoadFailureReason(err error) string {
	switch {
	case errors.Is(err, errContentHashMismatch):
		return "content_hash_mismatch"
	case errors.Is(err, errDownloadTooLarge):
		return "download_too_large"
	case errors.Is(err, errDownloadFailed):
		return "download_failed"
	case errors.Is(err, errPluginWasmUnavailable):
		return "wasm_unavailable"
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, context.Canceled):
		return "load_timeout"
	default:
		return "load_failed"
	}
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

func assignmentStateContentHash(assignment *pluginAssignment) string {
	if assignment == nil {
		return ""
	}
	if assignment.ContentHash != "" {
		return assignment.ContentHash
	}

	return assignment.PackageID + "|" + assignment.WasmObject + "|" + assignment.Version
}

// prefetchAssignment warms the Wasm cache for an assignment that is not yet
// ready. It is called on every config apply, including the unchanged-config
// path that only refreshes download credentials, so a download URL that was
// missing or wrong and is later corrected is fetched immediately instead of
// waiting for the first scheduled run.
func (m *PluginManager) prefetchAssignment(assignment *pluginAssignment) {
	if assignment == nil {
		return
	}

	if state := m.assignmentState(assignment.AssignmentID); state.ready {
		return
	}

	downloadURL, _ := assignment.downloadCredentials()
	if strings.TrimSpace(downloadURL) == "" {
		if m.localStoreHasWasm(assignment) {
			return
		}
		// Without a download URL the binary can never be fetched; say so now
		// rather than leaving the operator to discover it when a run fails.
		m.logger.Warn().
			Str("assignment_id", assignment.AssignmentID).
			Str("plugin_id", assignment.PluginID).
			Str("package_id", assignment.PackageID).
			Msg("Plugin wasm prefetch skipped: assignment has no download URL; " +
				"check the control plane plugin storage public URL " +
				"(PLUGIN_STORAGE_PUBLIC_URL / AGENT_PLUGIN_STORAGE_PUBLIC_URL)")
		return
	}

	if !m.beginPrefetch(assignment.AssignmentID) {
		return
	}

	go func() {
		defer m.endPrefetch(assignment.AssignmentID)
		ctx, cancel := context.WithTimeout(m.ctx, pluginDefaultHTTPTimeout*2)
		defer cancel()
		if _, err := m.loadWasm(ctx, assignment); err != nil && !errors.Is(err, errPluginWasmUnavailable) {
			m.logger.Warn().
				Err(err).
				Str("assignment_id", assignment.AssignmentID).
				Msg("Plugin wasm prefetch failed")
			m.tryEnqueueResult(buildPluginErrorResult(assignment, "", fmt.Sprintf("wasm_prefetch_failed: %s", err)))
		}
	}()
}

// beginPrefetch claims the single in-flight prefetch slot for an assignment so
// repeated config applies do not stack concurrent downloads of one binary.
func (m *PluginManager) beginPrefetch(assignmentID string) bool {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	state := m.states[assignmentID]
	if state == nil {
		state = &assignmentState{firstSeen: m.stateNow()}
		m.states[assignmentID] = state
	}
	if state.ready || state.prefetching {
		return false
	}
	state.prefetching = true
	return true
}

func (m *PluginManager) endPrefetch(assignmentID string) {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	if state := m.states[assignmentID]; state != nil {
		state.prefetching = false
	}
}

func (m *PluginManager) localStoreHasWasm(assignment *pluginAssignment) bool {
	if assignment == nil || assignment.WasmObject == "" {
		return false
	}
	localPath, err := safeJoin(m.localStoreDir, assignment.WasmObject)
	if err != nil {
		return false
	}
	_, err = os.Stat(localPath)
	return err == nil
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

func (m *PluginManager) downloadWasm(ctx context.Context, assignment *pluginAssignment) ([]byte, error) {
	downloadURL, downloadToken := assignment.downloadCredentials()
	if assignment == nil || strings.TrimSpace(downloadURL) == "" {
		return nil, errDownloadFailed
	}

	method := http.MethodGet
	if downloadToken != "" {
		method = http.MethodPost
	}

	req, err := http.NewRequestWithContext(ctx, method, downloadURL, nil)
	if err != nil {
		return nil, err
	}
	if downloadToken != "" {
		req.Header.Set("X-ServiceRadar-Plugin-Token", downloadToken)
	}

	client := m.artifactHTTPClient
	if client == nil {
		client = m.httpClient
	}
	if client == nil {
		return nil, errDownloadFailed
	}

	resp, err := client.Do(req)
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
