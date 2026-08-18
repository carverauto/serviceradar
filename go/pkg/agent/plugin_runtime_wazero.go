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

func (m *PluginManager) executeWithWasm(ctx context.Context, assignment *pluginAssignment, wasm []byte) error {
	runtime := wazero.NewRuntimeWithConfig(ctx, m.newRuntimeConfig(assignment.Resources.RequestedMemoryMB))
	defer func() {
		_ = runtime.Close(ctx)
	}()

	exec := newPluginExecution(m, assignment)
	defer exec.closeAll()

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
		m.tryEnqueueResult(buildPluginErrorResult(assignment, "no result submitted"))
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

	if downloadURL, _ := assignment.downloadCredentials(); downloadURL != "" {
		data, err := m.downloadWasm(ctx, assignment)
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

func assignmentStateContentHash(assignment *pluginAssignment) string {
	if assignment == nil {
		return ""
	}
	if assignment.ContentHash != "" {
		return assignment.ContentHash
	}

	return assignment.PackageID + "|" + assignment.WasmObject + "|" + assignment.Version
}

func (m *PluginManager) prefetchAssignment(assignment *pluginAssignment) {
	downloadURL, _ := assignment.downloadCredentials()
	if assignment == nil || downloadURL == "" {
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
