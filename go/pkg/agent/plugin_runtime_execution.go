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
	"errors"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

type pluginExecution struct {
	manager    *PluginManager
	assignment *pluginAssignment
	mode       pluginExecutionMode
	// assignmentGenerationBound is set only by the manager-owned Proxmox
	// streaming path after it registers the execution generation. Standalone
	// scheduled/action executions do not participate in that revocation lease.
	assignmentGenerationBound   bool
	configJSON                  []byte
	actionResult                []byte
	mediaBridge                 *pluginCameraMediaBridge
	consoleBridge               *pluginProxmoxConsoleBridge
	consoleSessionSpec          proxmoxConsoleSessionSpec
	credentialGrants            []credentialBrokerGrant
	authorizedRequestBody       []byte
	awxCallbackCredential       *awxCallbackCredentialMemoryInput
	credentialGrantMutationUses map[string]int
	proxmoxConsoleTicket        *proxmoxConsoleTicketState
	mu                          sync.Mutex
	conns                       map[uint32]net.Conn
	wsConns                     map[uint32]*websocket.Conn
	webSocketDialer             pluginWebSocketDialer
	artifactStreams             map[uint32]*pluginArtifactStream
	nextHandle                  uint32
	submitted                   bool
}

func newPluginExecution(manager *PluginManager, assignment *pluginAssignment) *pluginExecution {
	return &pluginExecution{
		manager:         manager,
		assignment:      assignment,
		mode:            pluginExecutionModeScheduled,
		configJSON:      assignment.ParamsJSON,
		conns:           make(map[uint32]net.Conn),
		wsConns:         make(map[uint32]*websocket.Conn),
		artifactStreams: make(map[uint32]*pluginArtifactStream),
		nextHandle:      1,
	}
}

func (e *pluginExecution) ensureActiveProxmoxAssignment(ctx context.Context) error {
	if e == nil || e.assignment == nil || !e.assignment.proxmoxHostAuthorityRequired ||
		e.manager == nil {
		return errPluginHostAuthorityDenied
	}
	if !e.assignmentGenerationBound {
		return nil
	}
	if ctx == nil {
		return errPluginHostAuthorityDenied
	}
	select {
	case <-ctx.Done():
		return errPluginHostAuthorityDenied
	default:
	}
	if !e.manager.pluginAssignmentGenerationActive(e.assignment, e.mode) {
		return errPluginHostAuthorityDenied
	}
	return nil
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
		WithFunc(e.hostEmitTelemetry).
		Export("emit_telemetry")
	builder.NewFunctionBuilder().
		WithFunc(e.hostArtifactOpen).
		Export("artifact_open")
	builder.NewFunctionBuilder().
		WithFunc(e.hostArtifactWrite).
		Export("artifact_write")
	builder.NewFunctionBuilder().
		WithFunc(e.hostArtifactCommit).
		Export("artifact_commit")
	builder.NewFunctionBuilder().
		WithFunc(e.hostArtifactAbort).
		Export("artifact_abort")
	builder.NewFunctionBuilder().
		WithFunc(e.hostCameraMediaOpen).
		Export("camera_media_open")
	builder.NewFunctionBuilder().
		WithFunc(e.hostCameraMediaWrite).
		Export("camera_media_write")
	builder.NewFunctionBuilder().
		WithFunc(e.hostCameraMediaHeartbeat).
		Export("camera_media_heartbeat")
	builder.NewFunctionBuilder().
		WithFunc(e.hostCameraMediaClose).
		Export("camera_media_close")
	builder.NewFunctionBuilder().
		WithFunc(e.hostProxmoxConsoleOpen).
		Export("proxmox_console_open")
	builder.NewFunctionBuilder().
		WithFunc(e.hostProxmoxConsoleWrite).
		Export("proxmox_console_write")
	builder.NewFunctionBuilder().
		WithFunc(e.hostProxmoxConsoleRead).
		Export("proxmox_console_read")
	builder.NewFunctionBuilder().
		WithFunc(e.hostProxmoxConsoleClose).
		Export("proxmox_console_close")
	builder.NewFunctionBuilder().
		WithFunc(e.hostProxmoxConsoleSSHConnect).
		Export("proxmox_console_ssh_connect")
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
	builder.NewFunctionBuilder().
		WithFunc(e.hostWebSocketConnect).
		Export("websocket_connect")
	builder.NewFunctionBuilder().
		WithFunc(e.hostWebSocketSend).
		Export("websocket_send")
	builder.NewFunctionBuilder().
		WithFunc(e.hostWebSocketRecv).
		Export("websocket_recv")
	builder.NewFunctionBuilder().
		WithFunc(e.hostWebSocketClose).
		Export("websocket_close")

	_, err := builder.Instantiate(ctx)
	return err
}

func (e *pluginExecution) hostGetConfig(_ context.Context, mod api.Module, ptr, size uint32) int32 {
	if !e.hasCapability("get_config") {
		return pluginErrDenied
	}

	payload := e.configJSON
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

func (e *pluginExecution) hostSubmitResult(ctx context.Context, mod api.Module, ptr, size uint32) int32 {
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
	maxPayloadBytes := pluginMaxPayloadBytes
	if e.mode == pluginExecutionModeAction && e.assignment.ingestsActionResults() {
		maxPayloadBytes = pluginMaxActionIngestResultBytes
	}
	if len(payload) > maxPayloadBytes {
		return pluginErrTooLarge
	}

	if e.mode == pluginExecutionModeAction {
		e.captureActionResult(payload)
		e.markSubmitted()
		return pluginErrOK
	}

	return e.submitScheduledResult(ctx, payload)
}

func (e *pluginExecution) submitScheduledResult(ctx context.Context, payload []byte) int32 {
	err := e.manager.enqueueResult(ctx, PluginResult{
		AssignmentID: e.assignment.AssignmentID,
		PluginID:     e.assignment.PluginID,
		PluginName:   e.assignment.Name,
		Payload:      payload,
		ObservedAt:   time.Now().UTC(),
	})
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return pluginErrTimeout
		}
		return pluginErrInternal
	}

	e.markSubmitted()

	return pluginErrOK
}

func (e *pluginExecution) hostCameraMediaOpen(ctx context.Context, mod api.Module, reqPtr, reqLen uint32) int32 {
	if !e.hasCapability(pluginCapabilityCameraMediaStream) || e.mediaBridge == nil {
		return pluginErrDenied
	}

	request, code := decodeCameraMediaOpenRequest(mod, reqPtr, reqLen)
	if code != pluginErrOK {
		return code
	}

	handle, err := e.mediaBridge.Open(ctx, request)
	if err != nil {
		return pluginCameraMediaErrorCode(err)
	}
	return int32(handle)
}

func (e *pluginExecution) hostCameraMediaWrite(
	ctx context.Context,
	mod api.Module,
	handle, metaPtr, metaLen, payloadPtr, payloadLen uint32,
) int32 {
	if !e.hasCapability(pluginCapabilityCameraMediaStream) || e.mediaBridge == nil {
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

	metadata, code := decodeCameraMediaChunkMetadata(mod, metaPtr, metaLen)
	if code != pluginErrOK {
		return code
	}

	written, err := e.mediaBridge.Write(ctx, handle, payload, metadata)
	if err != nil {
		return pluginCameraMediaErrorCode(err)
	}
	return int32(written)
}

func (e *pluginExecution) hostCameraMediaHeartbeat(
	_ context.Context,
	mod api.Module,
	handle, metaPtr, metaLen uint32,
) int32 {
	if !e.hasCapability(pluginCapabilityCameraMediaStream) || e.mediaBridge == nil {
		return pluginErrDenied
	}

	heartbeat, code := decodeCameraMediaHeartbeat(mod, metaPtr, metaLen)
	if code != pluginErrOK {
		return code
	}

	if err := e.mediaBridge.Heartbeat(handle, heartbeat); err != nil {
		return pluginCameraMediaErrorCode(err)
	}
	return pluginErrOK
}

func (e *pluginExecution) hostCameraMediaClose(
	_ context.Context,
	mod api.Module,
	handle, reasonPtr, reasonLen uint32,
) int32 {
	if !e.hasCapability(pluginCapabilityCameraMediaStream) || e.mediaBridge == nil {
		return pluginErrDenied
	}

	reason := ""
	if reasonLen > 0 {
		raw, ok := readMemory(mod, reasonPtr, reasonLen)
		if !ok {
			return pluginErrInvalid
		}
		reason = strings.TrimSpace(string(raw))
	}

	if err := e.mediaBridge.Close(handle, reason); err != nil {
		return pluginCameraMediaErrorCode(err)
	}
	return pluginErrOK
}

func (e *pluginExecution) markSubmitted() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.submitted = true
}

func (e *pluginExecution) captureActionResult(payload []byte) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.actionResult = append(e.actionResult[:0], payload...)
}

func (e *pluginExecution) capturedActionResult() []byte {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]byte(nil), e.actionResult...)
}

func (e *pluginExecution) hasSubmitted() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.submitted
}
