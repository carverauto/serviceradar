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
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

const (
	controlStreamReconnectDelay    = 5 * time.Second
	controlStreamHeartbeatInterval = 60 * time.Second
)

const (
	commandStatusFailed    = "failed"
	commandStatusSucceeded = "succeeded"
	notifierContractMajor  = "1"
)

// northboundActionResultSchema is the default result schema for a
// plugin.run_action command. Notification deliveries ride the same command type
// and answer with notificationDeliveryResultSchema instead; see
// pluginActionResultEnvelope.
const northboundActionResultSchema = "serviceradar.northbound_action_result.v1"

const (
	commandTypeMapperRun                   = "mapper.run_job"
	commandTypeSweepRun                    = "sweep.run_group"
	commandTypeMtrRun                      = "mtr.run"
	commandTypeMtrBulkRun                  = "mtr.bulk_run"
	commandTypeCameraRelayOpen             = "camera.open_relay"
	commandTypeCameraRelayStop             = "camera.close_relay"
	commandTypeAgentUpdate                 = "agent.update_release"
	commandTypeProxmoxTest                 = "proxmox.credential_test"
	commandTypePluginSnapshot              = "plugin.debug_snapshot"
	commandTypeSysmonDebugSpike            = "sysmon.debug_spike"
	commandTypePluginRunAction             = "plugin.run_action"
	commandTypeAddonRunCommand             = coreaddon.CommandTypeAddonRunCommand
	commandTypeEndpointInventoryCacheQuery = "endpoint_inventory.cache_query"
	commandTypeEndpointInventoryForceFresh = "endpoint_inventory.force_fresh_scan"
	// commandTypeAWXPrefix matches every AWX REST verb AwxClient dispatches
	// (awx.ping, awx.list_templates, awx.launch_job, ...). The verb set is
	// open-ended, so routing is by prefix rather than one case per verb.
	commandTypeAWXPrefix = "awx."
)

const (
	// awxPluginID is the plugin id core assigns the on-demand AWX bridge
	// under. The same wasm also ships as "awx-inventory-sync" with a
	// different entrypoint; command verbs must only run through the
	// run_check assignment, so the lookup is an exact id match.
	awxPluginID = "awx"

	// awxBrokeredAPITokenPlaceholder satisfies the awx plugin's non-empty
	// api_token validation without handing credential material to the Wasm
	// module. The real token is resolved from the command's credential
	// broker grant and injected as an Authorization header at the host HTTP
	// boundary (applyCredentialBrokerInjection overwrites the placeholder
	// header before the request leaves the agent).
	awxBrokeredAPITokenPlaceholder = "resolved-by-credential-broker"
)

const defaultOnDemandMtrDeadline = 45 * time.Second
const defaultMaxConcurrentOnDemandMtr = 2
const defaultAddonCommandTimeout = 300 * time.Second
const defaultAWXCommandTimeout = 60 * time.Second

var errControlStreamClosed = errors.New("control stream closed")

var (
	errMissingProxmoxCredentialBrokerGrant = errors.New("missing proxmox credential broker grant")
	errProxmoxCredentialBrokerUnavailable  = errors.New("credential broker unavailable")
	errDirectProxmoxAPITokenPayload        = errors.New("direct proxmox api token payloads are not allowed")
	errInvalidCredentialBrokerGrant        = errors.New("invalid credential broker grant")
	errCredentialBrokerGrantExpired        = errors.New("credential broker grant expired")
	errCredentialBrokerGrantDenied         = errors.New("credential broker grant denied")
	errMissingProxmoxBaseURL               = errors.New("missing proxmox base_url")
	errInvalidProxmoxBaseURL               = errors.New("invalid proxmox base_url")
	errInvalidProxmoxBaseURLScheme         = errors.New("invalid proxmox base_url scheme")
	errAWXPluginNotAssigned                = errors.New("awx plugin not assigned to this agent")
	errMissingAWXCredentialBrokerGrant     = errors.New("missing awx credential broker grant")
)

type mapperRunPayload struct {
	JobID   string   `json:"job_id"`
	JobName string   `json:"job_name"`
	Seeds   []string `json:"seeds,omitempty"`
}

type sweepRunPayload struct {
	SweepGroupID string `json:"sweep_group_id"`
}

type mtrRunPayload struct {
	Target   string `json:"target"`
	Protocol string `json:"protocol,omitempty"`
	MaxHops  int    `json:"max_hops,omitempty"`
}

type proxmoxCredentialTestPayload struct {
	Schema           string                       `json:"schema,omitempty"`
	CredentialRuleID string                       `json:"credential_rule_id,omitempty"`
	APIToken         string                       `json:"api_token"`
	CredentialBroker proxmoxCredentialBrokerGrant `json:"credential_broker,omitempty"`
	Target           proxmoxTestTarget            `json:"target"`
	TLS              proxmoxTestTLS               `json:"tls,omitempty"`
	TimeoutMS        int                          `json:"timeout_ms,omitempty"`
	Preview          map[string]any               `json:"preview,omitempty"`
	Metadata         map[string]string            `json:"metadata,omitempty"`
}

type proxmoxTestTarget = coreaddon.CredentialBrokerTarget

type proxmoxTestTLS struct {
	InsecureSkipVerify bool `json:"insecure_skip_verify,omitempty"`
}

type credentialBrokerGrant = coreaddon.CredentialBrokerGrant

type proxmoxCredentialBrokerGrant = credentialBrokerGrant

type pluginRunActionPayload struct {
	InvocationID       string          `json:"invocation_id"`
	ActionID           string          `json:"action_id"`
	PluginAssignmentID string          `json:"plugin_assignment_id"`
	PluginPackageID    string          `json:"plugin_package_id,omitempty"`
	Payload            json.RawMessage `json:"-"`
}

type addonRunCommandPayload struct {
	InvocationID      string            `json:"invocation_id"`
	ActionID          string            `json:"action_id"`
	AddonAssignmentID string            `json:"addon_assignment_id"`
	AddonPackageID    string            `json:"addon_package_id,omitempty"`
	AddonID           string            `json:"addon_id,omitempty"`
	Schema            string            `json:"schema,omitempty"`
	Metadata          map[string]string `json:"metadata,omitempty"`
	Payload           json.RawMessage   `json:"-"`
}

// awxCommandPayload is the serviceradar.awx_command.v1 payload Elixir's
// AwxClient dispatches for every awx.* verb. The verb/args/base_url fields
// become the awx plugin's run_check config; the credential broker grant
// stays host-side so the API token never enters the Wasm module.
type awxCommandPayload struct {
	Schema                       string                 `json:"schema,omitempty"`
	Verb                         string                 `json:"verb"`
	Args                         map[string]any         `json:"args,omitempty"`
	AuthorizedRequestBodyBase64  string                 `json:"authorized_request_body_b64,omitempty"`
	BaseURL                      string                 `json:"base_url"`
	ControllerID                 string                 `json:"controller_id,omitempty"`
	ControllerName               string                 `json:"controller_name,omitempty"`
	InsecureSkipVerify           bool                   `json:"insecure_skip_verify,omitempty"`
	CredentialBroker             *credentialBrokerGrant `json:"credential_broker,omitempty"`
	CallbackCredentialBindingRaw json.RawMessage        `json:"callback_credential_binding,omitempty"`
}

type credentialBrokerACL = coreaddon.CredentialBrokerACL
type credentialBrokerCachePolicy = coreaddon.CredentialBrokerCachePolicy

type proxmoxCredentialBrokerACL = credentialBrokerACL

type controlStreamSender struct {
	mu     sync.Mutex
	stream grpc.BidiStreamingClient[proto.ControlStreamRequest, proto.ControlStreamResponse]
	closed bool
}

func newControlStreamSender(stream grpc.BidiStreamingClient[proto.ControlStreamRequest, proto.ControlStreamResponse]) *controlStreamSender {
	return &controlStreamSender{stream: stream}
}

func (s *controlStreamSender) Send(req *proto.ControlStreamRequest) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errControlStreamClosed
	}
	return s.stream.Send(req)
}

func (s *controlStreamSender) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	_ = s.stream.CloseSend()
	s.mu.Unlock()
}

func (p *PushLoop) controlStreamLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-p.stopCh:
			return
		default:
		}

		if !p.isEnrolled() {
			time.Sleep(time.Second)
			continue
		}

		if !p.gateway.IsConnected() {
			p.logger.Warn().Msg("Control stream unavailable; reconnecting to gateway")

			if err := p.gateway.ReconnectWithBackoff(ctx); err != nil {
				p.logger.Warn().Err(err).Msg("Control stream gateway reconnect failed")
				continue
			}
		}

		stream, err := p.gateway.ControlStream(ctx)
		if err != nil {
			p.logger.Warn().Err(err).Msg("Control stream connection failed")
			select {
			case <-ctx.Done():
				return
			case <-time.After(controlStreamReconnectDelay):
				continue
			}
		}

		sender := newControlStreamSender(stream)
		if err := p.sendControlHello(sender); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to send control stream hello")
			sender.Close()
			select {
			case <-ctx.Done():
				return
			case <-time.After(controlStreamReconnectDelay):
				continue
			}
		}

		if err := p.handleControlStream(ctx, stream, sender); err != nil {
			if !errors.Is(err, io.EOF) {
				p.logger.Warn().Err(err).Msg("Control stream ended with error")
			}

			if err := p.gateway.Disconnect(); err != nil {
				p.logger.Warn().Err(err).Msg("Failed to reset gateway connection after control stream ended")
			}
		}

		sender.Close()

		select {
		case <-ctx.Done():
			return
		case <-time.After(controlStreamReconnectDelay):
			continue
		}
	}
}

func (p *PushLoop) superviseControlStreamLoop(ctx context.Context) {
	for {
		panicked := false

		func() {
			defer func() {
				if recovered := recover(); recovered != nil {
					panicked = true
					p.logger.Error().
						Interface("panic", recovered).
						Bytes("stack", debug.Stack()).
						Msg("Control stream loop panicked; restarting")
				}
			}()

			p.controlStreamLoop(ctx)
		}()

		if !panicked || ctx.Err() != nil {
			return
		}

		select {
		case <-ctx.Done():
			return
		case <-p.stopCh:
			return
		case <-time.After(controlStreamReconnectDelay):
		}
	}
}

func (p *PushLoop) sendControlHello(sender *controlStreamSender) error {
	req := p.buildControlHelloRequest()

	if err := sender.Send(req); err != nil {
		return err
	}

	if err := p.sendPendingReleaseActivationReport(sender); err != nil {
		p.logger.Warn().Err(err).Msg("Failed to send pending release activation report")
	}

	return nil
}

func (p *PushLoop) buildControlHelloRequest() *proto.ControlStreamRequest {
	p.server.mu.RLock()
	var cfg ServerConfig
	if p.server.config != nil {
		cfg = *p.server.config
	}
	agentID := cfg.AgentID
	partition := cfg.Partition
	configSource := normalizeConfigSourceLabel(p.server.config)
	p.server.mu.RUnlock()
	hostname, err := os.Hostname()
	if err != nil {
		hostname = ""
	}

	return &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_Hello{
			Hello: &proto.ControlStreamHello{
				AgentId:                  agentID,
				Partition:                partition,
				Capabilities:             p.getAgentCapabilities(&cfg),
				ConfigVersion:            p.getConfigVersion(),
				Version:                  Version,
				Hostname:                 hostname,
				Os:                       runtime.GOOS,
				Arch:                     runtime.GOARCH,
				Labels:                   deploymentHelloLabels(),
				ConfigSource:             configSource,
				AppliedPluginAssignments: p.appliedPluginAssignmentPolicyAcks(),
				// Report the agent's own host IP so the gateway links it to the
				// correct device even when the TCP peer IP is NAT'd (external agents).
				// Mirrors getSourceIP() used for PushStatus so the two agree.
				HostIp: p.getSourceIP(),
			},
		},
	}
}

func normalizeConfigSourceLabel(cfg *ServerConfig) string {
	switch {
	case cfg == nil:
		return ""
	case cfg.GatewayAddr == "":
		return "local"
	default:
		return "remote"
	}
}

func (p *PushLoop) handleControlStream(
	ctx context.Context,
	stream grpc.BidiStreamingClient[proto.ControlStreamRequest, proto.ControlStreamResponse],
	sender *controlStreamSender,
) error {
	heartbeatCtx, stopHeartbeat := context.WithCancel(ctx)
	defer stopHeartbeat()
	go p.controlStreamHeartbeatLoop(heartbeatCtx, sender)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-p.stopCh:
			return context.Canceled
		default:
		}

		resp, err := stream.Recv()
		if err != nil {
			return err
		}

		if cmd := resp.GetCommand(); cmd != nil {
			p.handleCommand(ctx, cmd, sender)
			continue
		}

		if cfg := resp.GetConfig(); cfg != nil {
			sequence := p.nextConfigSequence()
			if !p.applyConfigResponseWithSequence(ctx, cfg, "control", sequence) {
				p.logger.Warn().
					Str("config_version", cfg.ConfigVersion).
					Msg("Skipped control stream config ack because config apply failed")
				continue
			}
			if err := sender.Send(&proto.ControlStreamRequest{
				Payload: &proto.ControlStreamRequest_ConfigAck{ConfigAck: p.buildConfigAck(cfg.ConfigVersion)},
			}); err != nil {
				p.logger.Warn().
					Err(err).
					Str("config_version", cfg.ConfigVersion).
					Msg("Failed to send control stream config ack")
			}
		}

		if frame := resp.GetConsoleFrame(); frame != nil {
			p.handleConsoleFrame(ctx, frame, sender)
		}
	}
}

func (p *PushLoop) buildConfigAck(configVersion string) *proto.ConfigAck {
	return &proto.ConfigAck{
		ConfigVersion: configVersion,
		Timestamp:     time.Now().Unix(),
		// Per-section apply status: sections that failed permanently still
		// commit + ack, and this is where core learns about them.
		SectionStatuses:          p.configSectionAckStatuses(),
		AppliedPluginAssignments: p.appliedPluginAssignmentPolicyAcks(),
	}
}

func (p *PushLoop) controlStreamHeartbeatLoop(ctx context.Context, sender *controlStreamSender) {
	ticker := time.NewTicker(controlStreamHeartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-p.stopCh:
			return
		case <-ticker.C:
			if err := sender.Send(p.buildControlHelloRequest()); err != nil {
				p.logger.Warn().Err(err).Msg("Control stream heartbeat failed")
				sender.Close()
				return
			}
		}
	}
}

func (p *PushLoop) handleConsoleFrame(ctx context.Context, frame *proto.ConsoleFrame, sender *controlStreamSender) {
	if frame.GetSessionId() == "" {
		return
	}

	switch frame.GetFrameType() {
	case remoteaccess.FrameTypeFileTransferRequest, remoteaccess.FrameTypeFileTransferData:
		p.handleFileTransferFrame(ctx, frame, sender)
		return
	}
	if isApplicationAccessFrameType(frame.GetFrameType()) || isTCPAccessFrameType(frame.GetFrameType()) {
		p.handleAppTCPFrame(ctx, frame, sender)
		return
	}

	if p.remoteConsoleManager == nil {
		p.remoteConsoleManager = newRemoteConsoleManagerWithRoute(
			p.agentID(),
			gatewayIDFromClient(p.gateway),
			p.logger,
		)
		p.remoteConsoleManager.sshOptions.KnownHostsPath = remoteAccessKnownHostsFile(p.server)
	}

	p.remoteConsoleManager.HandleFrame(ctx, frame, sender)
}

func (p *PushLoop) agentID() string {
	if p == nil {
		return ""
	}

	return serverAgentID(p.server)
}

func (p *PushLoop) handleCommand(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if cmd == nil {
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("command_type", cmd.CommandType).
		Int("payload_bytes", len(cmd.PayloadJson)).
		Int64("ttl_seconds", cmd.TtlSeconds).
		Int64("created_at", cmd.CreatedAt).
		Msg("Received control command")

	if err := sender.Send(&proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandAck{
			CommandAck: &proto.CommandAck{
				CommandId:   cmd.CommandId,
				CommandType: cmd.CommandType,
				Timestamp:   time.Now().Unix(),
				Message:     "command received",
			},
		},
	}); err != nil {
		p.logger.Warn().
			Err(err).
			Str("command_id", cmd.CommandId).
			Str("command_type", cmd.CommandType).
			Msg("Failed to send command ack")
	}

	if commandExpired(cmd) {
		p.logger.Warn().
			Str("command_id", cmd.CommandId).
			Str("command_type", cmd.CommandType).
			Msg("Dropping expired command")
		_ = sender.Send(commandResult(cmd, false, "command expired", nil))
		return
	}

	go func() {
		switch cmd.CommandType {
		case commandTypeMapperRun:
			p.handleMapperRun(ctx, cmd, sender)
		case commandTypeSweepRun:
			p.handleSweepRun(ctx, cmd, sender)
		case commandTypeMtrRun:
			p.handleMtrRun(ctx, cmd, sender)
		case commandTypeMtrBulkRun:
			p.handleMtrBulkRun(ctx, cmd, sender)
		case commandTypeAdhocScan:
			p.handleAdhocScan(ctx, cmd, sender)
		case commandTypeCameraRelayOpen:
			p.handleCameraRelayOpen(ctx, cmd, sender)
		case commandTypeCameraRelayStop:
			p.handleCameraRelayStop(ctx, cmd, sender)
		case commandTypeAgentUpdate:
			p.handleAgentUpdateRelease(ctx, cmd, sender)
		case commandTypeProxmoxTest:
			p.handleProxmoxCredentialTest(ctx, cmd, sender)
		case commandTypePluginSnapshot:
			p.handlePluginDebugSnapshot(cmd, sender)
		case commandTypeSysmonDebugSpike:
			p.handleSysmonDebugSpike(cmd, sender)
		case commandTypePluginRunAction:
			p.handlePluginRunAction(ctx, cmd, sender)
		case commandTypeAddonRunCommand:
			p.handleAddonRunCommand(ctx, cmd, sender)
		case commandTypeEndpointInventoryCacheQuery:
			p.handleEndpointInventoryCacheQuery(cmd, sender)
		case commandTypeEndpointInventoryForceFresh:
			p.handleEndpointInventoryForceFreshScan(ctx, cmd, sender)
		default:
			if strings.HasPrefix(cmd.CommandType, commandTypeAWXPrefix) {
				p.handleAWXCommand(ctx, cmd, sender)
				return
			}
			_ = sender.Send(commandResult(cmd, false, "unsupported command", nil))
		}
	}()
}

func (p *PushLoop) handlePluginDebugSnapshot(cmd *proto.CommandRequest, sender *controlStreamSender) {
	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	p.server.mu.RUnlock()

	if pluginManager == nil {
		_ = sender.Send(commandResult(cmd, false, "plugin manager unavailable", nil))
		return
	}

	_ = sender.Send(commandResult(cmd, true, "plugin snapshot captured", pluginManager.DebugSnapshot()))
}

// sysmonDebugSpikePayload is the control-stream payload for sysmon.debug_spike.
type sysmonDebugSpikePayload struct {
	Metric  string  `json:"metric"`  // "cpu" or "memory"
	Value   float64 `json:"value"`   // spiked value (CPU %, or memory used %)
	Samples int     `json:"samples"` // consecutive spike samples to inject (0 -> default)
}

// handleSysmonDebugSpike injects a one-shot synthetic CPU/memory anomaly so the
// edge->core->persist->surface chain can be validated on demand (test/debug).
func (p *PushLoop) handleSysmonDebugSpike(cmd *proto.CommandRequest, sender *controlStreamSender) {
	p.server.mu.RLock()
	svc := p.server.sysmonService
	p.server.mu.RUnlock()

	if svc == nil {
		_ = sender.Send(commandResult(cmd, false, "sysmon service unavailable", nil))
		return
	}

	req := sysmonDebugSpikePayload{Metric: "cpu", Value: 95.0}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &req); err != nil {
			_ = sender.Send(commandResult(cmd, false, fmt.Sprintf("invalid sysmon.debug_spike payload: %v", err), nil))
			return
		}
	}

	written, err := svc.InjectSyntheticSpike(req.Metric, req.Value, req.Samples)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	_ = sender.Send(commandResult(cmd, true,
		fmt.Sprintf("injected %d synthetic %s spike sample(s) at %.1f", written, req.Metric, req.Value),
		map[string]any{"metric": req.Metric, "value": req.Value, "samples": written}))
}

// handlePluginRunAction runs one plugin.run_action command.
//
// A NOTIFICATION delivery rides this same command type on purpose (design D3):
// the platform-resident agent and a site agent are the same binary running the
// same wazero host, so a notifier authored for the edge runs unchanged on the
// control plane. Adding a second command type would fork that. What tells the
// two apart is the payload's `schema` discriminator, decoded once here and
// carried through the result as pluginActionResultEnvelope.
//
// Only two things differ for a notification: how the target assignment is
// addressed - a notification channel binds to a provider, not to an assignment,
// so the payload may name only `plugin_package_id` and
// resolveNotificationAssignmentID places it - and which correlation identity is
// stamped on the result.
func (p *PushLoop) handlePluginRunAction(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	payload := pluginRunActionPayload{Payload: cmd.PayloadJson}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid plugin action payload",
				pluginActionResultEnvelope{}.failure("invalid_payload")))
			return
		}
		payload.Payload = cmd.PayloadJson
	}

	notification, isNotification := decodeNotificationDelivery(payload.Payload)
	envelope := pluginActionResultEnvelope{
		notification:   notification,
		isNotification: isNotification,
		invocationID:   payload.InvocationID,
		actionID:       payload.ActionID,
	}

	if isNotification {
		if err := notification.validate(); err != nil {
			_ = sender.Send(commandResult(cmd, false, err.Error(),
				envelope.failure("invalid_notification_envelope")))
			return
		}
	} else if strings.TrimSpace(payload.PluginAssignmentID) == "" {
		_ = sender.Send(commandResult(cmd, false, "missing plugin_assignment_id",
			envelope.failure("missing_plugin_assignment_id")))
		return
	}

	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	p.server.mu.RUnlock()

	if pluginManager == nil {
		_ = sender.Send(commandResult(cmd, false, "plugin manager unavailable",
			envelope.failure("plugin_manager_unavailable")))
		return
	}

	assignmentID := strings.TrimSpace(payload.PluginAssignmentID)
	if isNotification {
		resolved, err := pluginManager.resolveNotificationAssignmentID(assignmentID, notification)
		if err != nil {
			_ = sender.Send(commandResult(cmd, false, err.Error(),
				envelope.failure(notificationTargetErrorCode(err))))
			return
		}
		assignmentID = resolved
	}

	timeout := commandRemainingTimeout(cmd, pluginDefaultTimeout)
	if timeout <= 0 {
		_ = sender.Send(commandResult(cmd, false, "command expired",
			envelope.failure("command_expired")))
		return
	}

	_ = sender.Send(commandProgress(cmd, 10, envelope.progressMessage()))

	resultBytes, err := pluginManager.RunAction(ctx, assignmentID, payload.Payload, timeout)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), envelope.failure(err.Error())))
		return
	}

	resultPayload := map[string]interface{}{}
	if len(resultBytes) > 0 {
		if err := json.Unmarshal(resultBytes, &resultPayload); err != nil {
			status := commandStatusSucceeded
			if isNotification {
				status = commandStatusFailed
			}
			resultPayload = map[string]interface{}{
				"schema":            envelope.schema(),
				"status":            status,
				"raw_result_base64": base64.StdEncoding.EncodeToString(resultBytes),
			}
		}
	}
	if isNotification {
		enforceNotifierContractVersion(resultPayload)
	}
	envelope.stamp(resultPayload)

	commandSucceeded := pluginActionCommandSucceeded(envelope, resultPayload)
	message := envelope.completedMessage()
	if !commandSucceeded {
		message = envelope.failedMessage()
	}
	_ = sender.Send(commandResult(cmd, commandSucceeded, message, resultPayload))
}

// enforceNotifierContractVersion prevents a successful-looking result from a
// contract major this host does not understand from settling a delivery. An
// absent version remains accepted during the pre-release rolling bridge; once
// a guest declares a version, malformed and unsupported majors fail closed.
func enforceNotifierContractVersion(resultPayload map[string]interface{}) {
	rawVersion, exists := resultPayload["sdk_contract_version"]
	if !exists || rawVersion == nil {
		return
	}

	version, ok := rawVersion.(string)
	version = strings.TrimSpace(version)
	major := version
	if before, _, found := strings.Cut(version, "."); found {
		major = before
	}

	if !ok || version == "" || major != notifierContractMajor {
		resultPayload["schema"] = notificationDeliveryResultSchema
		resultPayload["status"] = commandStatusFailed
		resultPayload["error_class"] = "sdk_contract_mismatch"
		resultPayload["error_message"] = "notifier SDK contract major is unsupported"
	}
}

func pluginActionCommandSucceeded(
	envelope pluginActionResultEnvelope,
	resultPayload map[string]interface{},
) bool {
	if envelope.isNotification {
		// The outer command state is transport, not notifier semantics. Only a
		// notifier's explicit delivered result is successful; retryable and
		// permanent failures stay distinguishable in payload_json for core.
		return resultPayload["schema"] == notificationDeliveryResultSchema &&
			resultPayload["status"] == "delivered"
	}

	return resultPayload["status"] != commandStatusFailed ||
		resultPayload["schema"] != actionResultAckSchema
}

// pluginActionResultEnvelope is the correlation identity the agent stamps on a
// plugin.run_action command result, and the one place that decides whether a
// result is a northbound action result or a notification delivery result.
//
// The agent never invents the BODY of a guest result. Whatever the plugin
// submitted is passed through and only these identity fields plus the
// schema/status defaults are filled in - the same courier role the northbound
// path already plays for invocation_id / action_id. Synthesising a notification
// result shape here would fork the notifier guest ABI the SDKs own (tasks 3.8).
type pluginActionResultEnvelope struct {
	notification   notificationDeliveryEnvelope
	isNotification bool
	invocationID   string
	actionID       string
}

func (e pluginActionResultEnvelope) schema() string {
	if e.isNotification {
		return notificationDeliveryResultSchema
	}

	return northboundActionResultSchema
}

// failure builds the terminal result for a dispatch that never reached the
// guest. It still carries the delivery identity, because a delivery the control
// plane cannot correlate is a delivery it has to time out instead of read.
func (e pluginActionResultEnvelope) failure(errorCode string) map[string]interface{} {
	result := map[string]interface{}{
		"schema": e.schema(),
		"status": commandStatusFailed,
		"error":  errorCode,
	}
	e.stampIdentity(result)

	return result
}

func (e pluginActionResultEnvelope) stamp(result map[string]interface{}) {
	result["schema"] = firstNonEmptyString(result["schema"], e.schema())
	defaultStatus := commandStatusSucceeded
	if e.isNotification {
		// A notifier that omitted its three-state result did not prove delivery.
		defaultStatus = commandStatusFailed
	}
	result["status"] = firstNonEmptyString(result["status"], defaultStatus)
	e.stampIdentity(result)
}

func (e pluginActionResultEnvelope) stampIdentity(result map[string]interface{}) {
	if e.isNotification {
		result["delivery_id"] = firstNonEmptyString(result["delivery_id"], e.notification.DeliveryID)
		result["channel_id"] = firstNonEmptyString(result["channel_id"], e.notification.ChannelID)
		result["action_key"] = firstNonEmptyString(result["action_key"], e.notification.ActionKey)
		return
	}

	result["invocation_id"] = firstNonEmptyString(result["invocation_id"], e.invocationID)
	result["action_id"] = firstNonEmptyString(result["action_id"], e.actionID)
}

func (e pluginActionResultEnvelope) progressMessage() string {
	if e.isNotification {
		return "starting notification delivery"
	}

	return "starting plugin action"
}

func (e pluginActionResultEnvelope) completedMessage() string {
	if e.isNotification {
		return "notification delivery completed"
	}

	return "plugin action completed"
}

func (e pluginActionResultEnvelope) failedMessage() string {
	if e.isNotification {
		return "notification delivery failed"
	}

	return "plugin action failed"
}

// notificationTargetErrorCode maps an addressing failure to a stable error code
// the delivery log can group on, rather than to the raw message text.
func notificationTargetErrorCode(err error) string {
	switch {
	case errors.Is(err, errNotificationTargetMissing):
		return "missing_notification_target"
	case errors.Is(err, errNotificationTargetAmbiguous):
		return "ambiguous_notification_target"
	case errors.Is(err, errPluginAssignmentNotFound):
		return "notifier_not_assigned"
	default:
		return "notification_target_unresolved"
	}
}

func (p *PushLoop) handleAddonRunCommand(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	payload := addonRunCommandPayload{Payload: cmd.PayloadJson}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid addon command payload", map[string]interface{}{
				"schema": "serviceradar.northbound_action_result.v1",
				"status": "failed",
				"error":  "invalid_payload",
			}))
			return
		}
		payload.Payload = cmd.PayloadJson
	}

	if strings.TrimSpace(payload.AddonAssignmentID) == "" {
		_ = sender.Send(commandResult(cmd, false, "missing addon_assignment_id", map[string]interface{}{
			"schema": "serviceradar.northbound_action_result.v1",
			"status": "failed",
			"error":  "missing_addon_assignment_id",
		}))
		return
	}

	p.server.mu.RLock()
	addonManager := p.server.addonManager
	p.server.mu.RUnlock()

	if addonManager == nil {
		_ = sender.Send(commandResult(cmd, false, "addon manager unavailable", map[string]interface{}{
			"schema": "serviceradar.northbound_action_result.v1",
			"status": "failed",
			"error":  "addon_manager_unavailable",
		}))
		return
	}

	timeout := commandRemainingTimeout(cmd, defaultAddonCommandTimeout)
	if timeout <= 0 {
		_ = sender.Send(commandResult(cmd, false, "command expired", map[string]interface{}{
			"schema": "serviceradar.northbound_action_result.v1",
			"status": "failed",
			"error":  "command_expired",
		}))
		return
	}

	_ = sender.Send(commandProgress(cmd, 10, "starting addon command"))

	result, err := addonManager.RunCommand(ctx, agentaddon.CommandInvocation{
		AssignmentID: payload.AddonAssignmentID,
		AddonID:      payload.AddonID,
		CommandID:    cmd.CommandId,
		CommandType:  cmd.CommandType,
		ActionID:     payload.ActionID,
		Schema:       payload.Schema,
		PayloadJSON:  payload.Payload,
		Timeout:      timeout,
		DeadlineUnix: time.Now().Add(timeout).Unix(),
		Metadata:     payload.Metadata,
	})
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), map[string]interface{}{
			"schema":              "serviceradar.northbound_action_result.v1",
			"status":              "failed",
			"error":               err.Error(),
			"invocation_id":       payload.InvocationID,
			"action_id":           payload.ActionID,
			"addon_assignment_id": payload.AddonAssignmentID,
			"addon_package_id":    payload.AddonPackageID,
		}))
		return
	}

	resultPayload := map[string]interface{}{}
	if len(result.PayloadJSON) > 0 {
		if err := json.Unmarshal(result.PayloadJSON, &resultPayload); err != nil {
			resultPayload = map[string]interface{}{
				"schema":            "serviceradar.northbound_action_result.v1",
				"status":            resultStatus(result.Success),
				"raw_result_base64": base64.StdEncoding.EncodeToString(result.PayloadJSON),
			}
		}
	}
	resultPayload["schema"] = firstNonEmptyString(resultPayload["schema"], "serviceradar.northbound_action_result.v1")
	resultPayload["status"] = firstNonEmptyString(resultPayload["status"], resultStatus(result.Success))
	resultPayload["invocation_id"] = firstNonEmptyString(resultPayload["invocation_id"], payload.InvocationID)
	resultPayload["action_id"] = firstNonEmptyString(resultPayload["action_id"], payload.ActionID)
	resultPayload["addon_assignment_id"] = firstNonEmptyString(resultPayload["addon_assignment_id"], payload.AddonAssignmentID)
	resultPayload["addon_package_id"] = firstNonEmptyString(resultPayload["addon_package_id"], payload.AddonPackageID)
	if len(result.Metadata) > 0 {
		resultPayload["metadata"] = result.Metadata
	}

	message := result.Message
	if strings.TrimSpace(message) == "" {
		message = "addon command completed"
	}

	_ = sender.Send(commandResult(cmd, result.Success, message, resultPayload))
}

func resultStatus(success bool) string {
	if success {
		return commandStatusSucceeded
	}
	return commandStatusFailed
}

// handleAWXCommand routes awx.* command verbs to the locally assigned awx
// plugin's run_check entrypoint. The serviceradar.awx_command.v1 payload is
// translated into the plugin's config (verb/args/base_url), and the command's
// credential broker grant rides host-side through the same action-mode
// machinery plugin.run_action uses, so the API token is injected at the host
// HTTP boundary and never enters the Wasm module.
func (p *PushLoop) handleAWXCommand(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	payload := awxCommandPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid awx command payload", nil))
			return
		}
	}

	if payload.CredentialBroker == nil ||
		strings.TrimSpace(payload.CredentialBroker.CredentialSecretRef) == "" {
		_ = sender.Send(commandResult(cmd, false, errMissingAWXCredentialBrokerGrant.Error(), nil))
		return
	}

	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	p.server.mu.RUnlock()

	if pluginManager == nil {
		_ = sender.Send(commandResult(cmd, false, "plugin manager unavailable", nil))
		return
	}

	timeout := commandRemainingTimeout(cmd, defaultAWXCommandTimeout)
	if timeout <= 0 {
		_ = sender.Send(commandResult(cmd, false, "command expired", nil))
		return
	}

	configJSON, err := buildAWXPluginConfig(cmd, payload)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, "failed to build awx plugin config", nil))
		return
	}

	_ = sender.Send(commandProgress(cmd, 10, "starting awx verb"))

	grants := []credentialBrokerGrant{*payload.CredentialBroker}
	authorizedRequestBody, err := decodeAWXAuthorizedRequestBody(payload.AuthorizedRequestBodyBase64)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, errInvalidCredentialBrokerGrant.Error(), nil))
		return
	}
	defer clear(authorizedRequestBody)

	resultBytes, err := p.runAWXPluginVerb(
		ctx,
		pluginManager,
		cmd,
		payload,
		configJSON,
		grants,
		authorizedRequestBody,
		timeout,
	)
	if err != nil {
		message := err.Error()
		if errors.Is(err, errPluginAssignmentNotFound) {
			message = errAWXPluginNotAssigned.Error()
		}
		_ = sender.Send(commandResult(cmd, false, message, nil))
		return
	}

	verb := strings.TrimSpace(payload.Verb)
	if verb == "" {
		verb = strings.TrimSpace(cmd.CommandType)
	}
	success, message, resultPayload := parseAWXPluginResult(resultBytes, verb)
	_ = sender.Send(commandResult(cmd, success, message, resultPayload))
}

func (p *PushLoop) runAWXPluginVerb(
	ctx context.Context,
	pluginManager *PluginManager,
	cmd *proto.CommandRequest,
	payload awxCommandPayload,
	configJSON []byte,
	grants []credentialBrokerGrant,
	authorizedRequestBody []byte,
	timeout time.Duration,
) ([]byte, error) {
	verb := strings.TrimSpace(payload.Verb)
	if verb == "" {
		verb = strings.TrimSpace(cmd.CommandType)
	}
	isCreate := verb == "awx.create_callback_credential"
	isDelete := verb == "awx.delete_callback_credential"
	if !isCreate && !isDelete {
		if len(bytes.TrimSpace(payload.CallbackCredentialBindingRaw)) > 0 {
			return nil, errAWXCallbackCredentialBindingInvalid
		}
		return pluginManager.RunPluginVerbWithAuthorizedRequestBody(
			ctx,
			awxPluginID,
			configJSON,
			grants,
			authorizedRequestBody,
			timeout,
		)
	}
	if len(authorizedRequestBody) != 0 {
		return nil, errInvalidCredentialBrokerGrant
	}
	if strings.TrimSpace(cmd.CommandType) != verb {
		return nil, errAWXCallbackCredentialBindingInvalid
	}
	if err := validateAWXCallbackCredentialCommandArgs(payload.Args, isDelete); err != nil {
		return nil, err
	}

	binding, err := decodeAWXCallbackCredentialBinding(payload.CallbackCredentialBindingRaw)
	if err != nil {
		return nil, err
	}
	binding, err = validateAWXCallbackCredentialBinding(
		binding,
		cmd.CommandId,
		p.agentID(),
		payload.ControllerID,
		payload.Args,
		isDelete,
	)
	if err != nil {
		return nil, err
	}
	if isDelete {
		credentialID, ok := awxCallbackArgInt(payload.Args, "credential_id")
		if !ok || !positiveAWXID(credentialID) {
			return nil, errAWXCallbackCredentialBindingInvalid
		}
		return pluginManager.RunPluginVerb(ctx, awxPluginID, configJSON, grants, timeout)
	}

	callbackInput, err := resolveAWXCallbackCredentialMemoryInput(
		ctx,
		pluginManager.awxCallbackCredentialEnvelopeResolver(),
		binding,
		pluginManager.credentialNowTime(),
	)
	if err != nil {
		return nil, err
	}
	defer callbackInput.destroy()

	return pluginManager.RunPluginVerbWithAWXCallbackCredential(
		ctx,
		awxPluginID,
		configJSON,
		grants,
		callbackInput,
		timeout,
	)
}

func decodeAWXAuthorizedRequestBody(encoded string) ([]byte, error) {
	encoded = strings.TrimSpace(encoded)
	if encoded == "" {
		return nil, nil
	}
	body, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(body) == 0 || len(body) > pluginMaxPayloadBytes {
		clear(body)
		return nil, errInvalidCredentialBrokerGrant
	}
	return body, nil
}

// buildAWXPluginConfig translates a serviceradar.awx_command.v1 payload into
// the config shape the awx plugin's run_check entrypoint loads via
// get_config: top-level verb, args, base_url, insecure_skip_verify and a
// placeholder api_token (see awxBrokeredAPITokenPlaceholder).
func buildAWXPluginConfig(cmd *proto.CommandRequest, payload awxCommandPayload) ([]byte, error) {
	verb := strings.TrimSpace(payload.Verb)
	if verb == "" {
		verb = strings.TrimSpace(cmd.CommandType)
	}

	config := map[string]any{
		"verb":      verb,
		"base_url":  payload.BaseURL,
		"api_token": awxBrokeredAPITokenPlaceholder,
	}
	if len(payload.Args) > 0 {
		config["args"] = payload.Args
	}
	if payload.InsecureSkipVerify {
		config["insecure_skip_verify"] = true
	}

	return json.Marshal(config)
}

// parseAWXPluginResult unpacks the sdk result envelope the awx plugin
// submitted. Success mirrors the plugin's status, and the details JSON — the
// typed per-verb payload core's AnsibleEventIngestor parses (ok/job/jobs/...)
// — becomes the command result payload.
func parseAWXPluginResult(resultBytes []byte, expectedVerb string) (success bool, message string, payload map[string]any) {
	expectedVerb = strings.TrimSpace(expectedVerb)
	envelope := struct {
		Status  string `json:"status"`
		Summary string `json:"summary"`
		Details string `json:"details"`
	}{}
	if err := json.Unmarshal(resultBytes, &envelope); err != nil {
		return safeAWXPluginFailure(expectedVerb, "invalid awx plugin result")
	}

	success = strings.EqualFold(strings.TrimSpace(envelope.Status), "OK")
	if !success {
		return safeAWXPluginFailure(expectedVerb, "awx command failed")
	}

	details := strings.TrimSpace(envelope.Details)
	if details == "" {
		return safeAWXPluginFailure(expectedVerb, "invalid awx plugin result")
	}

	decoded := map[string]any{}
	if err := json.Unmarshal([]byte(details), &decoded); err != nil {
		return safeAWXPluginFailure(expectedVerb, "invalid awx plugin result")
	}
	if decodedVerb, ok := decoded["verb"].(string); !ok || decodedVerb != expectedVerb || decoded["ok"] != true {
		return safeAWXPluginFailure(expectedVerb, "invalid awx plugin result")
	}

	return true, "awx command completed", decoded
}

func safeAWXPluginFailure(expectedVerb, message string) (bool, string, map[string]any) {
	payload := map[string]any{"ok": false}
	if expectedVerb != "" {
		payload["verb"] = expectedVerb
	}
	return false, message, payload
}

func (p *PushLoop) handleMapperRun(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	payload := mapperRunPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid mapper payload", nil))
			return
		}
	}

	if payload.JobName == "" {
		_ = sender.Send(commandResult(cmd, false, "missing job_name", nil))
		return
	}

	p.server.mu.RLock()
	mapperSvc := p.server.mapperService
	p.server.mu.RUnlock()

	if mapperSvc == nil {
		_ = sender.Send(commandResult(cmd, false, "mapper service unavailable", nil))
		return
	}

	var discoveryID string

	var err error
	if len(payload.Seeds) > 0 {
		discoveryID, err = mapperSvc.RunScheduledJobWithSeeds(ctx, payload.JobName, payload.Seeds)
	} else {
		discoveryID, err = mapperSvc.RunScheduledJob(ctx, payload.JobName)
	}
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	resultPayload := map[string]interface{}{
		"discovery_id": discoveryID,
		"job_id":       payload.JobID,
		"job_name":     payload.JobName,
	}
	if len(payload.Seeds) > 0 {
		resultPayload["seeds"] = payload.Seeds
	}

	_ = sender.Send(commandResult(cmd, true, "mapper run started", resultPayload))
}

func (p *PushLoop) handleSweepRun(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	payload := sweepRunPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			p.logger.Warn().
				Err(err).
				Str("command_id", cmd.CommandId).
				Str("command_type", cmd.CommandType).
				Msg("Invalid sweep command payload")
			_ = sender.Send(commandResult(cmd, false, "invalid sweep payload", nil))
			return
		}
	}

	if payload.SweepGroupID == "" {
		p.logger.Warn().
			Str("command_id", cmd.CommandId).
			Str("command_type", cmd.CommandType).
			Msg("Sweep command missing sweep_group_id")
		_ = sender.Send(commandResult(cmd, false, "missing sweep_group_id", nil))
		return
	}

	if err := p.runSweepGroup(ctx, payload.SweepGroupID); err != nil {
		p.logger.Warn().
			Err(err).
			Str("command_id", cmd.CommandId).
			Str("command_type", cmd.CommandType).
			Str("sweep_group_id", payload.SweepGroupID).
			Msg("Failed to run sweep group")
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("command_type", cmd.CommandType).
		Str("sweep_group_id", payload.SweepGroupID).
		Msg("Sweep run started")

	resultPayload := map[string]interface{}{
		"sweep_group_id": payload.SweepGroupID,
	}

	_ = sender.Send(commandResult(cmd, true, "sweep run started", resultPayload))
}

func (p *PushLoop) runSweepGroup(ctx context.Context, groupID string) error {
	p.server.mu.RLock()
	services := append([]Service(nil), p.server.services...)
	p.server.mu.RUnlock()

	for _, svc := range services {
		if runner, ok := svc.(interface {
			RunSweepGroup(context.Context, string) error
		}); ok {
			p.logger.Info().
				Str("sweep_group_id", groupID).
				Str("service", svc.Name()).
				Msg("Dispatching on-demand sweep run to service")
			return runner.RunSweepGroup(ctx, groupID)
		}
	}

	serviceNames := make([]string, 0, len(services))
	for _, svc := range services {
		serviceNames = append(serviceNames, svc.Name())
	}
	p.logger.Warn().
		Str("sweep_group_id", groupID).
		Strs("services", serviceNames).
		Msg("No sweep runner available for on-demand sweep")

	return errSweepRunnerUnavailable
}

func (p *PushLoop) handleMtrRun(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if !p.tryAcquireOnDemandMtrSlot() {
		_ = sender.Send(commandResult(cmd, false, "agent busy: too many concurrent mtr traces", nil))
		return
	}
	defer p.releaseOnDemandMtrSlot()

	payload := mtrRunPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid mtr payload", nil))
			return
		}
	}

	if payload.Target == "" {
		_ = sender.Send(commandResult(cmd, false, "missing target", nil))
		return
	}

	runTimeout := commandTimeoutCap(cmd)
	if runTimeout <= 0 {
		_ = sender.Send(commandResult(cmd, false, "command deadline exceeded", nil))
		return
	}

	runCtx, cancel := context.WithTimeout(ctx, runTimeout)
	defer cancel()

	opts := onDemandMtrOptions(payload)
	trace, err := runOnDemandMtr(runCtx, opts, p.logger)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	traceJSON, err := json.Marshal(trace)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, "failed to marshal trace", nil))
		return
	}

	resultPayload := map[string]any{
		"target": payload.Target,
		"trace":  json.RawMessage(traceJSON),
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("target", payload.Target).
		Bool("target_reached", trace.TargetReached).
		Int("total_hops", trace.TotalHops).
		Msg("On-demand MTR trace completed")

	_ = sender.Send(commandResult(cmd, true, "mtr trace completed", resultPayload))
}

func (p *PushLoop) handleProxmoxCredentialTest(
	ctx context.Context,
	cmd *proto.CommandRequest,
	sender *controlStreamSender,
) {
	payload := proxmoxCredentialTestPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid proxmox credential test payload", nil))
			return
		}
	}

	runTimeout := commandTimeoutCap(cmd)
	if runTimeout <= 0 {
		_ = sender.Send(commandResult(cmd, false, "command deadline exceeded", nil))
		return
	}

	runCtx, cancel := context.WithTimeout(ctx, runTimeout)
	defer cancel()

	result, err := runProxmoxCredentialTest(runCtx, payload)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), result))
		return
	}

	_ = sender.Send(commandResult(cmd, true, "proxmox credential test completed", result))
}

func (p *PushLoop) handleCameraRelayOpen(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if p.cameraRelayManager == nil {
		_ = sender.Send(commandResult(cmd, false, "camera relay manager unavailable", nil))
		return
	}

	payload := cameraRelayStartPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid camera relay payload", nil))
			return
		}
	}

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	p.server.mu.RUnlock()

	state, err := p.cameraRelayManager.Start(ctx, cameraRelaySessionSpec{
		RelaySessionID:     payload.RelaySessionID,
		AgentID:            agentID,
		GatewayID:          p.gateway.GetGatewayID(),
		CameraSourceID:     payload.CameraSourceID,
		StreamProfileID:    payload.StreamProfileID,
		LeaseToken:         payload.LeaseToken,
		PluginAssignmentID: payload.PluginAssignmentID,
		SourceURL:          payload.SourceURL,
		RTSPTransport:      payload.RTSPTransport,
		CodecHint:          payload.CodecHint,
		ContainerHint:      payload.ContainerHint,
		InsecureSkipVerify: payload.InsecureSkipVerify,
	})
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	_ = sender.Send(commandResult(cmd, true, "camera relay started", map[string]interface{}{
		"relay_session_id":      state.RelaySessionID,
		"media_ingest_id":       state.MediaIngestID,
		"lease_expires_at_unix": state.LeaseExpiresAtUnix,
	}))
}

func (p *PushLoop) handleCameraRelayStop(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if p.cameraRelayManager == nil {
		_ = sender.Send(commandResult(cmd, false, "camera relay manager unavailable", nil))
		return
	}

	payload := cameraRelayStopPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid camera relay stop payload", nil))
			return
		}
	}

	stopCtx, cancel := context.WithTimeout(ctx, defaultCameraRelayCloseTimeout)
	defer cancel()

	if err := p.cameraRelayManager.Stop(stopCtx, payload); err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	_ = sender.Send(commandResult(cmd, true, "camera relay stopped", map[string]interface{}{
		"relay_session_id": payload.RelaySessionID,
	}))
}

func (p *PushLoop) handleAgentUpdateRelease(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	payload := releaseUpdatePayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid release update payload", map[string]interface{}{
				"status": "failed",
				"reason": "invalid_payload",
			}))
			return
		}
	}

	_ = sender.Send(commandProgress(cmd, 10, "downloading"))

	p.server.mu.RLock()
	stageCfg := releaseStageConfig{
		RuntimeRoot:     "",
		GatewayAddr:     p.server.config.GatewayAddr,
		GatewaySecurity: p.server.config.GatewaySecurity,
		CommandID:       cmd.CommandId,
	}
	p.server.mu.RUnlock()

	result, err := stageAgentRelease(ctx, payload, stageCfg)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), map[string]interface{}{
			"status": "failed",
			"reason": err.Error(),
		}))
		return
	}

	_ = sender.Send(commandProgress(cmd, 60, "verifying"))
	_ = sender.Send(commandProgress(cmd, 80, "staged"))

	updaterPath, err := ValidatedAgentUpdaterPath()
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, "failed to prepare updater activation", map[string]interface{}{
			"status": "failed",
			"reason": err.Error(),
		}))
		return
	}

	execArgs, err := validateReleaseActivationExecArgs(result.Version, cmd.CommandId, cmd.CommandType)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, "failed to validate updater activation arguments", map[string]interface{}{
			"status": "failed",
			"reason": err.Error(),
		}))
		return
	}

	updaterCmd := exec.CommandContext(
		ctx,
		updaterPath,
		"--runtime-root", result.RuntimeRoot,
		"--version", execArgs.Version,
		"--command-id", execArgs.CommandID,
		"--command-type", execArgs.CommandType,
		"--rollback-deadline", "3m0s",
	)
	updaterCmd.Stdout = os.Stdout
	updaterCmd.Stderr = os.Stderr
	if err := updaterCmd.Run(); err != nil {
		_ = sender.Send(commandResult(cmd, false, "failed to prepare updater activation", map[string]interface{}{
			"status": "failed",
			"reason": err.Error(),
		}))
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("version", result.Version).
		Msg("Prepared agent updater activation")

	_ = sender.Send(commandProgress(cmd, 90, "switching"))
	_ = sender.Send(commandProgress(cmd, 95, "restarting"))

	go func() {
		time.Sleep(250 * time.Millisecond)
		requestSelfTermination()
	}()
}

func (p *PushLoop) sendPendingReleaseActivationReport(sender *controlStreamSender) error {
	report, err := LoadReleaseActivationReport("")
	if err != nil || report == nil {
		return err
	}

	req := &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandResult{
			CommandResult: &proto.CommandResult{
				CommandId:   report.CommandID,
				CommandType: report.CommandType,
				Success:     report.Success,
				Message:     report.Message,
				Timestamp:   time.Now().Unix(),
			},
		},
	}
	if len(report.Payload) > 0 {
		req.GetCommandResult().PayloadJson, _ = json.Marshal(report.Payload)
	}

	if err := sender.Send(req); err != nil {
		return err
	}
	return ClearReleaseActivationReport("")
}

func (p *PushLoop) tryAcquireOnDemandMtrSlot() bool {
	if p == nil || p.mtrOnDemandSem == nil {
		return true
	}

	select {
	case p.mtrOnDemandSem <- struct{}{}:
		return true
	default:
		return false
	}
}

func (p *PushLoop) releaseOnDemandMtrSlot() {
	if p == nil || p.mtrOnDemandSem == nil {
		return
	}

	select {
	case <-p.mtrOnDemandSem:
	default:
	}
}

func (p *PushLoop) tryAcquireBulkMtrJobSlot() bool {
	if p == nil || p.mtrBulkJobSem == nil {
		return true
	}

	select {
	case p.mtrBulkJobSem <- struct{}{}:
		return true
	default:
		return false
	}
}

func (p *PushLoop) releaseBulkMtrJobSlot() {
	if p == nil || p.mtrBulkJobSem == nil {
		return
	}

	select {
	case <-p.mtrBulkJobSem:
	default:
	}
}

func onDemandMtrOptions(payload mtrRunPayload) mtr.Options {
	target := strings.TrimSpace(payload.Target)
	opts := mtr.DefaultOptions(target)

	if protocol := strings.TrimSpace(payload.Protocol); protocol != "" {
		opts.Protocol = mtr.ParseProtocol(strings.ToLower(protocol))
	}

	if payload.MaxHops > 0 {
		opts.MaxHops = clampInt(payload.MaxHops, mtrMaxHopsUpperBound)
	}

	return opts
}

func runProxmoxCredentialTest(
	ctx context.Context,
	payload proxmoxCredentialTestPayload,
) (map[string]any, error) {
	_ = ctx

	baseURL, err := proxmoxCredentialTestBaseURL(payload.Target.BaseURL)
	if err != nil {
		return nil, err
	}

	if strings.TrimSpace(payload.APIToken) == "" {
		if err := validateProxmoxCredentialBrokerGrant(payload, baseURL); err != nil {
			return nil, err
		}

		return proxmoxCredentialTestResult(payload, baseURL, 0, 0), errProxmoxCredentialBrokerUnavailable
	}

	return nil, errDirectProxmoxAPITokenPayload
}

func validateProxmoxCredentialBrokerGrant(payload proxmoxCredentialTestPayload, baseURL string) error {
	grant := payload.CredentialBroker
	if strings.TrimSpace(grant.CredentialSecretRef) == "" {
		return errMissingProxmoxCredentialBrokerGrant
	}
	if strings.TrimSpace(grant.Schema) != "serviceradar.edge_credential_broker_grant.v1" {
		return errInvalidCredentialBrokerGrant
	}
	if strings.TrimSpace(grant.GrantID) == "" {
		return errInvalidCredentialBrokerGrant
	}
	if grant.GrantType != "proxmox_api_token" {
		return errInvalidCredentialBrokerGrant
	}
	if strings.TrimSpace(grant.CredentialRuleID) != "" &&
		strings.TrimSpace(payload.CredentialRuleID) != "" &&
		strings.TrimSpace(grant.CredentialRuleID) != strings.TrimSpace(payload.CredentialRuleID) {
		return errCredentialBrokerGrantDenied
	}
	if grant.TTLSeconds < 0 {
		return errInvalidCredentialBrokerGrant
	}
	if strings.TrimSpace(grant.ExpiresAt) != "" {
		expiresAt, err := time.Parse(time.RFC3339, strings.TrimSpace(grant.ExpiresAt))
		if err != nil {
			return errInvalidCredentialBrokerGrant
		}
		if !time.Now().Before(expiresAt) {
			return errCredentialBrokerGrantExpired
		}
	}
	if err := validateProxmoxGrantTarget(payload.Target, grant.Target, baseURL); err != nil {
		return err
	}
	if err := validateProxmoxGrantAllow(grant.Allow, baseURL); err != nil {
		return err
	}

	return nil
}

func validateProxmoxGrantTarget(commandTarget proxmoxTestTarget, grantTarget coreaddon.CredentialBrokerTarget, baseURL string) error {
	if strings.TrimSpace(grantTarget.Kind) != "" &&
		strings.TrimSpace(grantTarget.Kind) != "device" {
		return errCredentialBrokerGrantDenied
	}
	if strings.TrimSpace(grantTarget.AgentID) != "" &&
		strings.TrimSpace(commandTarget.AgentID) != "" &&
		strings.TrimSpace(grantTarget.AgentID) != strings.TrimSpace(commandTarget.AgentID) {
		return errCredentialBrokerGrantDenied
	}
	if strings.TrimSpace(grantTarget.DeviceUID) != "" &&
		strings.TrimSpace(commandTarget.DeviceUID) != "" &&
		strings.TrimSpace(grantTarget.DeviceUID) != strings.TrimSpace(commandTarget.DeviceUID) {
		return errCredentialBrokerGrantDenied
	}
	if strings.TrimSpace(grantTarget.ID) != "" &&
		strings.TrimSpace(commandTarget.DeviceUID) != "" &&
		strings.TrimSpace(grantTarget.ID) != strings.TrimSpace(commandTarget.DeviceUID) {
		return errCredentialBrokerGrantDenied
	}
	if strings.TrimSpace(grantTarget.BaseURL) != "" {
		grantBaseURL, err := proxmoxCredentialTestBaseURL(grantTarget.BaseURL)
		if err != nil {
			return errInvalidCredentialBrokerGrant
		}
		if grantBaseURL != baseURL {
			return errCredentialBrokerGrantDenied
		}
	}

	return nil
}

func validateProxmoxGrantAllow(allow proxmoxCredentialBrokerACL, baseURL string) error {
	if len(allow.Methods) > 0 && !stringInFoldedList("GET", allow.Methods) {
		return errCredentialBrokerGrantDenied
	}
	if len(allow.Paths) > 0 && !anyPathAllowed(allow.Paths, "/api2/json/version") {
		return errCredentialBrokerGrantDenied
	}
	if len(allow.Hosts) > 0 {
		parsed, err := url.Parse(baseURL)
		if err != nil || parsed.Host == "" {
			return errInvalidProxmoxBaseURL
		}
		host := parsed.Hostname()
		if !stringInFoldedList(host, allow.Hosts) && !stringInFoldedList(parsed.Host, allow.Hosts) {
			return errCredentialBrokerGrantDenied
		}
	}
	if len(allow.Ports) > 0 {
		parsed, err := url.Parse(baseURL)
		if err != nil || parsed.Host == "" {
			return errInvalidProxmoxBaseURL
		}
		port := portForURL(parsed)
		if port == 0 || !intInList(port, allow.Ports) {
			return errCredentialBrokerGrantDenied
		}
	}

	return nil
}

func anyPathAllowed(patterns []string, requested string) bool {
	for _, pattern := range patterns {
		pattern = strings.TrimSpace(pattern)
		switch {
		case pattern == requested:
			return true
		case strings.HasSuffix(pattern, "*") && strings.HasPrefix(requested, strings.TrimSuffix(pattern, "*")):
			return true
		}
	}

	return false
}

func stringInFoldedList(value string, list []string) bool {
	for _, item := range list {
		if strings.EqualFold(strings.TrimSpace(item), strings.TrimSpace(value)) {
			return true
		}
	}

	return false
}

func intInList(value int, list []int) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}

	return false
}

func portForURL(parsed *url.URL) int {
	if port := parsed.Port(); port != "" {
		return parsePositiveInt(port)
	}
	switch parsed.Scheme {
	case httpsScheme:
		return 443
	case httpScheme:
		return 80
	default:
		return 0
	}
}

func parsePositiveInt(value string) int {
	n := 0
	for _, r := range value {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}

func proxmoxCredentialTestBaseURL(raw string) (string, error) {
	value := strings.TrimRight(strings.TrimSpace(raw), "/")
	if value == "" {
		return "", errMissingProxmoxBaseURL
	}

	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" {
		return "", errInvalidProxmoxBaseURL
	}
	if parsed.Scheme != httpsScheme && parsed.Scheme != httpScheme {
		return "", errInvalidProxmoxBaseURLScheme
	}

	return value, nil
}

func proxmoxCredentialTestResult(
	payload proxmoxCredentialTestPayload,
	baseURL string,
	statusCode int,
	nodeCount int,
) map[string]any {
	result := map[string]any{
		"schema":             "serviceradar.proxmox_credential_test_result.v1",
		"credential_rule_id": payload.CredentialRuleID,
		"base_url":           baseURL,
		"status_code":        statusCode,
		"node_count":         nodeCount,
	}
	if payload.Target.DeviceUID != "" {
		result["device_uid"] = payload.Target.DeviceUID
	}
	if payload.Target.Hostname != "" {
		result["hostname"] = payload.Target.Hostname
	}
	if payload.Target.IP != "" {
		result["ip"] = payload.Target.IP
	}
	return result
}

func commandTimeoutCap(cmd *proto.CommandRequest) time.Duration {
	if defaultOnDemandMtrDeadline <= 0 {
		return 0
	}

	if cmd == nil || cmd.TtlSeconds <= 0 || cmd.CreatedAt <= 0 {
		return defaultOnDemandMtrDeadline
	}

	expiry := time.Unix(cmd.CreatedAt, 0).Add(time.Duration(cmd.TtlSeconds) * time.Second)
	remaining := time.Until(expiry)
	if remaining <= 0 {
		return 0
	}

	if remaining < defaultOnDemandMtrDeadline {
		return remaining
	}

	return defaultOnDemandMtrDeadline
}

func commandRemainingTimeout(cmd *proto.CommandRequest, fallback time.Duration) time.Duration {
	if cmd == nil || cmd.TtlSeconds <= 0 || cmd.CreatedAt <= 0 {
		return fallback
	}

	expiry := time.Unix(cmd.CreatedAt, 0).Add(time.Duration(cmd.TtlSeconds) * time.Second)
	remaining := time.Until(expiry)
	if remaining <= 0 {
		return 0
	}

	return remaining
}

func firstNonEmptyString(value any, fallback string) string {
	if text, ok := value.(string); ok {
		text = strings.TrimSpace(text)
		if text != "" {
			return text
		}
	}
	return fallback
}

func commandExpired(cmd *proto.CommandRequest) bool {
	if cmd == nil || cmd.TtlSeconds <= 0 || cmd.CreatedAt <= 0 {
		return false
	}

	expiry := time.Unix(cmd.CreatedAt, 0).Add(time.Duration(cmd.TtlSeconds) * time.Second)
	return time.Now().After(expiry)
}

func commandProgress(cmd *proto.CommandRequest, progressPercent int32, message string) *proto.ControlStreamRequest {
	return commandProgressWithPayload(cmd, progressPercent, message, nil)
}

func commandProgressWithPayload(
	cmd *proto.CommandRequest,
	progressPercent int32,
	message string,
	payload any,
) *proto.ControlStreamRequest {
	var payloadJSON []byte
	if payload != nil {
		payloadJSON, _ = json.Marshal(payload)
	}

	return &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandProgress{
			CommandProgress: &proto.CommandProgress{
				CommandId:       cmd.CommandId,
				CommandType:     cmd.CommandType,
				ProgressPercent: progressPercent,
				Message:         message,
				Timestamp:       time.Now().Unix(),
				PayloadJson:     payloadJSON,
			},
		},
	}
}

func commandResult(cmd *proto.CommandRequest, success bool, message string, payload any) *proto.ControlStreamRequest {
	var payloadJSON []byte
	if payload != nil {
		payloadJSON, _ = json.Marshal(payload)
	}

	return &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandResult{
			CommandResult: &proto.CommandResult{
				CommandId:   cmd.CommandId,
				CommandType: cmd.CommandType,
				Success:     success,
				Message:     message,
				PayloadJson: payloadJSON,
				Timestamp:   time.Now().Unix(),
			},
		},
	}
}
