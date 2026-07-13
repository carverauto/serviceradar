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
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
)

const (
	proxmoxConsolePluginInputBuffer = 64
	proxmoxConsolePluginReadTimeout = 100 * time.Millisecond
)

var (
	errProxmoxConsoleAssignmentScopeRequired         = errors.New("proxmox console plugin assignment id and credential rule id are required")
	errProxmoxConsoleAssignmentPolicyBindingRequired = errors.New("proxmox console assignment policy binding is required")
	errProxmoxConsoleAssignmentPolicyMismatch        = errors.New("proxmox console assignment policy binding does not match the active assignment")
)

type proxmoxConsoleOpenPayload struct {
	SessionID          string                  `json:"session_id"`
	AgentID            string                  `json:"agent_id,omitempty"`
	GatewayID          string                  `json:"gateway_id,omitempty"`
	DeviceUID          string                  `json:"device_uid,omitempty"`
	TargetKind         string                  `json:"target_kind,omitempty"`
	ConsoleMode        string                  `json:"console_mode,omitempty"`
	CredentialRuleID   string                  `json:"credential_rule_id,omitempty"`
	PluginAssignmentID string                  `json:"plugin_assignment_id,omitempty"`
	Target             proxmoxConsoleSSHTarget `json:"target,omitempty"`
	Cols               uint32                  `json:"cols,omitempty"`
	Rows               uint32                  `json:"rows,omitempty"`
}

type proxmoxConsoleSessionSpec struct {
	SessionID                   string                  `json:"session_id"`
	AgentID                     string                  `json:"agent_id,omitempty"`
	GatewayID                   string                  `json:"gateway_id,omitempty"`
	DeviceUID                   string                  `json:"device_uid,omitempty"`
	TargetKind                  string                  `json:"target_kind,omitempty"`
	ConsoleMode                 string                  `json:"console_mode,omitempty"`
	CredentialRuleID            string                  `json:"credential_rule_id,omitempty"`
	PluginAssignmentID          string                  `json:"plugin_assignment_id,omitempty"`
	AssignmentPolicyVersion     uint64                  `json:"-"`
	AssignmentPolicyFingerprint string                  `json:"-"`
	Target                      proxmoxConsoleSSHTarget `json:"target,omitempty"`
	Cols                        uint32                  `json:"cols,omitempty"`
	Rows                        uint32                  `json:"rows,omitempty"`
}

type pluginProxmoxConsoleOpenRequest struct {
	TerminalType string `json:"terminal_type,omitempty"`
}

type pluginProxmoxConsoleInputFrame struct {
	FrameType string `json:"frame_type"`
	Data      []byte `json:"data,omitempty"`
	Cols      uint32 `json:"cols,omitempty"`
	Rows      uint32 `json:"rows,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

type pluginProxmoxConsoleBridge struct {
	mu          sync.Mutex
	cancel      context.CancelFunc
	handle      uint32
	opened      bool
	closed      bool
	openCh      chan struct{}
	closeCh     chan struct{}
	output      chan []byte
	input       chan []byte
	resize      chan [2]uint32
	openRequest pluginProxmoxConsoleOpenRequest
	closeReason string
	err         error
}

func newPluginProxmoxConsoleBridge(cancel context.CancelFunc) *pluginProxmoxConsoleBridge {
	return &pluginProxmoxConsoleBridge{
		cancel:  cancel,
		handle:  1,
		openCh:  make(chan struct{}),
		closeCh: make(chan struct{}),
		output:  make(chan []byte, proxmoxConsolePluginInputBuffer),
		input:   make(chan []byte, proxmoxConsolePluginInputBuffer),
		resize:  make(chan [2]uint32, 8),
	}
}

func (m *PluginManager) OpenProxmoxConsoleStream(
	ctx context.Context,
	spec proxmoxConsoleSessionSpec,
) (proxmoxConsolePTY, error) {
	if m == nil {
		return nil, errProxmoxConsoleBridgeUnavailable
	}

	assignment, err := m.lookupProxmoxConsoleAssignment(spec)
	if err != nil {
		return nil, err
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

	configJSON, err := buildProxmoxConsolePluginConfig(assignment.ParamsJSON, spec)
	if err != nil {
		cancel()
		m.unregisterStreamingExecution(executionID)
		m.releaseSlot()
		return nil, err
	}

	bridge := newPluginProxmoxConsoleBridge(cancel)

	go func() {
		defer cancel()
		defer m.unregisterStreamingExecution(executionID)
		defer m.releaseSlot()

		execErr := m.executeProxmoxConsolePlugin(runCtx, assignment, wasm, configJSON, bridge, spec)
		switch {
		case execErr != nil:
			m.recordExecution(false)
			m.logger.Warn().
				Err(execErr).
				Str("assignment_id", assignment.AssignmentID).
				Str("session_id", spec.SessionID).
				Msg("Proxmox console streaming plugin execution failed")
			bridge.finish(execErr)

		case !bridge.hasOpened():
			m.recordExecution(false)
			bridge.finish(errStreamingPluginConsoleNotOpened)

		default:
			m.recordExecution(true)
			bridge.finish(io.EOF)
		}
	}()

	if err := bridge.waitOpen(ctx); err != nil {
		_ = bridge.Close()
		return nil, err
	}

	return bridge, nil
}

func (m *PluginManager) lookupProxmoxConsoleAssignment(spec proxmoxConsoleSessionSpec) (*pluginAssignment, error) {
	assignmentID := strings.TrimSpace(spec.PluginAssignmentID)
	credentialRuleID := strings.TrimSpace(spec.CredentialRuleID)
	if assignmentID == "" || credentialRuleID == "" {
		return nil, errProxmoxConsoleAssignmentScopeRequired
	}

	assignment, ok := m.lookupStreamingAssignment(assignmentID)
	if !ok || assignment == nil || assignment.PluginID != proxmoxConsolePluginID ||
		assignment.Entrypoint != proxmoxConsoleEntrypoint ||
		!assignment.Capabilities[pluginCapabilityProxmoxConsole] ||
		!assignment.proxmoxHostAuthorityRequired {
		return nil, fmt.Errorf("%w %q", errStreamingPluginAssignmentNotFound, assignmentID)
	}
	if assignmentCredentialRuleID(assignment) != credentialRuleID {
		return nil, fmt.Errorf("%w %q for credential rule %q", errStreamingPluginAssignmentNotFound, assignmentID, credentialRuleID)
	}
	activePolicy, ok := assignment.proxmoxAssignmentPolicyBinding()
	if !ok || activePolicy.PolicyVersion != spec.AssignmentPolicyVersion ||
		activePolicy.Fingerprint != spec.AssignmentPolicyFingerprint ||
		activePolicy.CredentialRuleID != credentialRuleID {
		return nil, fmt.Errorf("%w %q", errProxmoxConsoleAssignmentPolicyMismatch, assignmentID)
	}
	return assignment, nil
}

func (m *PluginManager) executeProxmoxConsolePlugin(
	ctx context.Context,
	assignment *pluginAssignment,
	wasm []byte,
	configJSON []byte,
	bridge *pluginProxmoxConsoleBridge,
	spec proxmoxConsoleSessionSpec,
) error {
	if m.consoleExecutor != nil {
		return m.consoleExecutor(ctx, assignment, wasm, configJSON, bridge)
	}
	return m.executeProxmoxConsoleWithWasm(ctx, assignment, wasm, configJSON, bridge, spec)
}

func (m *PluginManager) executeProxmoxConsoleWithWasm(
	ctx context.Context,
	assignment *pluginAssignment,
	wasm []byte,
	configJSON []byte,
	bridge *pluginProxmoxConsoleBridge,
	spec proxmoxConsoleSessionSpec,
) error {
	runtimeCfg := m.newRuntimeConfig(assignment.Resources.RequestedMemoryMB)

	runtime := wazero.NewRuntimeWithConfig(ctx, runtimeCfg)
	defer func() {
		_ = runtime.Close(ctx)
	}()

	exec := newPluginExecution(m, assignment)
	defer exec.closeAll()
	exec.mode = pluginExecutionModeStreaming
	exec.assignmentGenerationBound = true
	exec.configJSON = configJSON
	exec.consoleBridge = bridge
	exec.consoleSessionSpec = spec

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

	fn := module.ExportedFunction(assignment.Entrypoint)
	if fn == nil {
		return errEntrypointNotFound
	}

	if _, err := fn.Call(ctx); err != nil {
		return fmt.Errorf("entrypoint failed: %w", err)
	}

	return nil
}

func buildProxmoxConsolePluginConfig(baseParams []byte, spec proxmoxConsoleSessionSpec) ([]byte, error) {
	console := map[string]interface{}{
		"session_id":           spec.SessionID,
		"agent_id":             spec.AgentID,
		"gateway_id":           spec.GatewayID,
		"device_uid":           spec.DeviceUID,
		"target_kind":          spec.TargetKind,
		"console_mode":         spec.ConsoleMode,
		"credential_rule_id":   spec.CredentialRuleID,
		"plugin_assignment_id": spec.PluginAssignmentID,
		"cols":                 spec.Cols,
		"rows":                 spec.Rows,
	}

	if len(bytes.TrimSpace(baseParams)) == 0 {
		return json.Marshal(proxmoxConsolePluginConfigWithTarget(map[string]interface{}{"console": console}, spec))
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(baseParams, &parsed); err == nil {
		parsed["console"] = console
		return json.Marshal(proxmoxConsolePluginConfigWithTarget(parsed, spec))
	}

	return json.Marshal(map[string]interface{}{
		"console":                  console,
		"target":                   spec.Target,
		"plugin_config_raw_base64": base64.StdEncoding.EncodeToString(baseParams),
	})
}

func proxmoxConsolePluginConfigWithTarget(config map[string]interface{}, spec proxmoxConsoleSessionSpec) map[string]interface{} {
	if spec.Target.DeviceUID != "" || spec.Target.Hostname != "" || spec.Target.IP != "" ||
		spec.Target.BaseURL != "" || spec.Target.SSHPort > 0 || spec.Target.ProviderRef != "" ||
		spec.Target.TargetRef != "" || spec.Target.IntegrationID != "" || spec.Target.Cluster != "" ||
		spec.Target.Node != "" || spec.Target.OwnerNode != "" || spec.Target.VMID > 0 ||
		spec.Target.ControllerID != "" || spec.Target.ProviderInstanceRef != "" ||
		spec.Target.NativeClusterID != "" || spec.Target.ObjectKind != "" || spec.Target.NativeObjectID != "" {
		config["target"] = spec.Target
	}
	return config
}

func decodeProxmoxConsoleOpenPayload(frame *proto.ConsoleFrame) (proxmoxConsoleSessionSpec, error) {
	if frame == nil {
		return proxmoxConsoleSessionSpec{}, errProxmoxConsoleBridgeUnavailable
	}

	var payload proxmoxConsoleOpenPayload
	if len(bytes.TrimSpace(frame.GetData())) > 0 {
		if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
			return proxmoxConsoleSessionSpec{}, fmt.Errorf("decode proxmox console open payload: %w", err)
		}
	}

	spec := proxmoxConsoleSessionSpec{
		SessionID:                   firstNonEmpty(payload.SessionID, frame.GetSessionId()),
		AgentID:                     strings.TrimSpace(payload.AgentID),
		GatewayID:                   strings.TrimSpace(payload.GatewayID),
		DeviceUID:                   strings.TrimSpace(payload.DeviceUID),
		TargetKind:                  strings.TrimSpace(payload.TargetKind),
		ConsoleMode:                 strings.TrimSpace(payload.ConsoleMode),
		CredentialRuleID:            strings.TrimSpace(payload.CredentialRuleID),
		PluginAssignmentID:          strings.TrimSpace(payload.PluginAssignmentID),
		AssignmentPolicyVersion:     frame.GetAssignmentPolicyVersion(),
		AssignmentPolicyFingerprint: strings.TrimSpace(frame.GetAssignmentPolicyFingerprint()),
		Target:                      payload.Target,
		Cols:                        firstNonZero(payload.Cols, frame.GetCols()),
		Rows:                        firstNonZero(payload.Rows, frame.GetRows()),
	}
	if spec.SessionID == "" {
		return proxmoxConsoleSessionSpec{}, errProxmoxConsoleSessionNotActive
	}
	if spec.PluginAssignmentID == "" || spec.CredentialRuleID == "" {
		return proxmoxConsoleSessionSpec{}, errProxmoxConsoleAssignmentScopeRequired
	}
	if spec.AssignmentPolicyVersion == 0 ||
		!validProxmoxAssignmentPolicyFingerprint(spec.AssignmentPolicyFingerprint) {
		return proxmoxConsoleSessionSpec{}, errProxmoxConsoleAssignmentPolicyBindingRequired
	}

	return spec, nil
}

func assignmentCredentialRuleID(assignment *pluginAssignment) string {
	if assignment != nil && assignment.proxmoxHostAuthorityRequired {
		return assignment.proxmoxHostAuthorityCredentialRuleID()
	}
	if assignment == nil || len(bytes.TrimSpace(assignment.ParamsJSON)) == 0 {
		return ""
	}

	var params map[string]interface{}
	if err := json.Unmarshal(assignment.ParamsJSON, &params); err != nil {
		return ""
	}

	if value, ok := params["credential_rule_id"].(string); ok {
		return strings.TrimSpace(value)
	}

	broker, _ := params["credential_broker"].(map[string]interface{})
	if value, ok := broker["credential_rule_id"].(string); ok {
		return strings.TrimSpace(value)
	}

	return ""
}

func (b *pluginProxmoxConsoleBridge) waitOpen(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-b.openCh:
		b.mu.Lock()
		defer b.mu.Unlock()
		if b.err != nil {
			return b.err
		}
		if !b.opened {
			return errStreamingPluginConsoleNotOpened
		}
		return nil
	}
}

func (b *pluginProxmoxConsoleBridge) Open(_ context.Context, req pluginProxmoxConsoleOpenRequest) (uint32, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.closed {
		return 0, firstError(b.err, errProxmoxConsoleSessionNotActive)
	}
	if b.opened {
		return 0, errProxmoxConsoleSessionExists
	}

	b.opened = true
	b.openRequest = req
	close(b.openCh)

	return b.handle, nil
}

func (b *pluginProxmoxConsoleBridge) Read(ctx context.Context) ([]byte, error) {
	select {
	case data := <-b.output:
		return data, nil
	case <-b.closeCh:
		return nil, firstError(b.terminalErr(), io.EOF)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (b *pluginProxmoxConsoleBridge) Write(data []byte) error {
	if len(data) == 0 {
		return nil
	}
	if !b.isOpen() {
		return errProxmoxConsoleSessionNotActive
	}

	copied := append([]byte(nil), data...)
	select {
	case b.input <- copied:
		return nil
	case <-b.closeCh:
		return firstError(b.terminalErr(), errProxmoxConsoleSessionNotActive)
	}
}

func (b *pluginProxmoxConsoleBridge) Resize(cols, rows uint32) error {
	if cols == 0 || rows == 0 {
		return nil
	}
	if !b.isOpen() {
		return errProxmoxConsoleSessionNotActive
	}

	select {
	case b.resize <- [2]uint32{cols, rows}:
		return nil
	case <-b.closeCh:
		return firstError(b.terminalErr(), errProxmoxConsoleSessionNotActive)
	}
}

func (b *pluginProxmoxConsoleBridge) Close() error {
	b.finish(io.EOF)
	return nil
}

func (b *pluginProxmoxConsoleBridge) WriteOutput(ctx context.Context, handle uint32, data []byte) (int, error) {
	if len(data) == 0 {
		return 0, errProxmoxConsoleSessionNotActive
	}
	if !b.validHandle(handle) {
		return 0, errProxmoxConsoleSessionNotActive
	}

	copied := append([]byte(nil), data...)
	select {
	case b.output <- copied:
		return len(copied), nil
	case <-b.closeCh:
		return 0, firstError(b.terminalErr(), errProxmoxConsoleSessionNotActive)
	case <-ctx.Done():
		return 0, ctx.Err()
	}
}

func (b *pluginProxmoxConsoleBridge) ReadInput(ctx context.Context, handle uint32, timeout time.Duration) (pluginProxmoxConsoleInputFrame, error) {
	if !b.validHandle(handle) {
		return pluginProxmoxConsoleInputFrame{}, errProxmoxConsoleSessionNotActive
	}
	if timeout <= 0 {
		timeout = proxmoxConsolePluginReadTimeout
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case data := <-b.input:
		return pluginProxmoxConsoleInputFrame{FrameType: consoleFrameTypeData, Data: data}, nil
	case size := <-b.resize:
		return pluginProxmoxConsoleInputFrame{FrameType: consoleFrameTypeResize, Cols: size[0], Rows: size[1]}, nil
	case <-b.closeCh:
		return pluginProxmoxConsoleInputFrame{FrameType: consoleFrameTypeClose, Reason: b.reason()}, io.EOF
	case <-ctx.Done():
		return pluginProxmoxConsoleInputFrame{}, ctx.Err()
	case <-timer.C:
		return pluginProxmoxConsoleInputFrame{}, context.DeadlineExceeded
	}
}

func (b *pluginProxmoxConsoleBridge) CloseHandle(handle uint32, reason string) error {
	if !b.validHandle(handle) {
		return errProxmoxConsoleSessionNotActive
	}

	b.mu.Lock()
	b.closeReason = strings.TrimSpace(reason)
	b.mu.Unlock()
	b.finish(io.EOF)
	return nil
}

func (b *pluginProxmoxConsoleBridge) reason() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.closeReason
}

func (b *pluginProxmoxConsoleBridge) hasOpened() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.opened
}

func (b *pluginProxmoxConsoleBridge) isOpen() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.opened && !b.closed
}

func (b *pluginProxmoxConsoleBridge) validHandle(handle uint32) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.opened && !b.closed && handle == b.handle
}

func (b *pluginProxmoxConsoleBridge) activeHandle() (uint32, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.opened || b.closed {
		return 0, errProxmoxConsoleSessionNotActive
	}
	return b.handle, nil
}

func (b *pluginProxmoxConsoleBridge) finish(err error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.closed {
		return
	}
	b.closed = true
	b.err = err
	if b.cancel != nil {
		b.cancel()
	}
	if !b.opened {
		close(b.openCh)
	}
	close(b.closeCh)
}

func (b *pluginProxmoxConsoleBridge) terminalErr() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.err
}

func (e *pluginExecution) hostProxmoxConsoleOpen(ctx context.Context, mod api.Module, reqPtr, reqLen uint32) int32 {
	if !e.hasCapability(pluginCapabilityProxmoxConsole) || e.consoleBridge == nil {
		return pluginErrDenied
	}

	req, code := decodeProxmoxConsoleOpenRequest(mod, reqPtr, reqLen)
	if code != pluginErrOK {
		return code
	}

	handle, err := e.consoleBridge.Open(ctx, req)
	if err != nil {
		return proxmoxConsolePluginErrorCode(err)
	}

	return int32(handle)
}

func (e *pluginExecution) hostProxmoxConsoleWrite(
	ctx context.Context,
	mod api.Module,
	handle, payloadPtr, payloadLen uint32,
) int32 {
	if !e.hasCapability(pluginCapabilityProxmoxConsole) || e.consoleBridge == nil {
		return pluginErrDenied
	}

	payload, ok := readMemory(mod, payloadPtr, payloadLen)
	if !ok {
		return pluginErrInvalid
	}
	if len(payload) == 0 {
		return pluginErrInvalid
	}
	if len(payload) > pluginMaxPayloadBytes {
		return pluginErrTooLarge
	}

	written, err := e.consoleBridge.WriteOutput(ctx, handle, payload)
	if err != nil {
		return proxmoxConsolePluginErrorCode(err)
	}

	return int32(written)
}

func (e *pluginExecution) hostProxmoxConsoleRead(
	ctx context.Context,
	mod api.Module,
	handle, bufPtr, bufLen, timeoutMS uint32,
) int32 {
	if !e.hasCapability(pluginCapabilityProxmoxConsole) || e.consoleBridge == nil {
		return pluginErrDenied
	}

	frame, err := e.consoleBridge.ReadInput(ctx, handle, time.Duration(timeoutMS)*time.Millisecond)
	if err != nil {
		return proxmoxConsolePluginErrorCode(err)
	}

	payload, err := json.Marshal(frame)
	if err != nil {
		return pluginErrInternal
	}
	if len(payload) > int(bufLen) {
		return pluginErrTooLarge
	}
	if !writeMemory(mod, bufPtr, payload) {
		return pluginErrInvalid
	}

	return int32(len(payload))
}

func (e *pluginExecution) hostProxmoxConsoleClose(
	_ context.Context,
	mod api.Module,
	handle, reasonPtr, reasonLen uint32,
) int32 {
	if !e.hasCapability(pluginCapabilityProxmoxConsole) || e.consoleBridge == nil {
		return pluginErrDenied
	}

	reason := ""
	if reasonLen > 0 {
		raw, ok := readMemory(mod, reasonPtr, reasonLen)
		if !ok {
			return pluginErrInvalid
		}
		reason = string(raw)
	}

	if err := e.consoleBridge.CloseHandle(handle, reason); err != nil {
		return proxmoxConsolePluginErrorCode(err)
	}

	return pluginErrOK
}

func (e *pluginExecution) hostProxmoxConsoleSSHConnect(ctx context.Context, mod api.Module, configPtr, configLen uint32) int32 {
	if !e.hasCapability(pluginCapabilityProxmoxConsole) || e.consoleBridge == nil {
		return pluginErrDenied
	}

	raw, ok := readMemory(mod, configPtr, configLen)
	if !ok {
		return pluginErrInvalid
	}
	if len(raw) == 0 {
		return pluginErrInvalid
	}
	if len(raw) > pluginMaxPayloadBytes {
		return pluginErrTooLarge
	}

	var request proxmoxConsoleSSHHostRequest
	if err := decodeStrictJSON(raw, &request); err != nil || strings.TrimSpace(request.SessionID) == "" {
		return pluginErrInvalid
	}
	cfg, err := e.trustedProxmoxConsoleSSHConfig(ctx, request.SessionID)
	if err != nil {
		return proxmoxConsolePluginErrorCode(err)
	}
	cfg.revalidate = e.ensureActiveProxmoxAssignment

	if err := runProxmoxConsoleSSH(ctx, cfg, e.consoleBridge, nil); err != nil {
		return proxmoxConsolePluginErrorCode(err)
	}

	return pluginErrOK
}

func decodeProxmoxConsoleOpenRequest(mod api.Module, ptr, size uint32) (pluginProxmoxConsoleOpenRequest, int32) {
	if size == 0 {
		return pluginProxmoxConsoleOpenRequest{}, pluginErrOK
	}
	raw, ok := readMemory(mod, ptr, size)
	if !ok {
		return pluginProxmoxConsoleOpenRequest{}, pluginErrInvalid
	}
	if len(raw) > pluginMaxPayloadBytes {
		return pluginProxmoxConsoleOpenRequest{}, pluginErrTooLarge
	}

	var request pluginProxmoxConsoleOpenRequest
	if err := json.Unmarshal(raw, &request); err != nil {
		return pluginProxmoxConsoleOpenRequest{}, pluginErrInvalid
	}

	return request, pluginErrOK
}

func proxmoxConsolePluginErrorCode(err error) int32 {
	switch {
	case err == nil:
		return pluginErrOK
	case errors.Is(err, errProxmoxConsoleSessionNotActive), errors.Is(err, io.EOF):
		return pluginErrNotFound
	case errors.Is(err, context.DeadlineExceeded):
		return pluginErrTimeout
	default:
		return pluginErrInternal
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func firstNonZero(values ...uint32) uint32 {
	for _, value := range values {
		if value > 0 {
			return value
		}
	}
	return 0
}

func firstError(values ...error) error {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}
