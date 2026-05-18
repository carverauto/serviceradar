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

package remoteaccess

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"
)

const (
	FrameTypeEnhancedEvent = "enhanced_event"

	EnhancedEventCommand = "command"
	EnhancedEventFile    = "file"
	EnhancedEventNetwork = "network"
	EnhancedEventLoss    = "loss"
)

var ErrEnhancedRecordingUnavailable = errors.New("enhanced recording unavailable")
var ErrEnhancedRecordingTargetBoundaryRequired = errors.New("target-side enhanced recording requires managed target execution")

const (
	EnhancedExecutionManagedTarget = "managed_target"
	enhancedPolicyModeHostEvents   = "host_events"
)

// EnhancedRecordingPolicy is the agent-visible subset of the platform policy.
// It controls whether host-event tracing is required before target access opens
// and which sensitive fields are allowed in emitted events.
type EnhancedRecordingPolicy struct {
	Enabled                 bool   `json:"enabled,omitempty"`
	Required                bool   `json:"required,omitempty"`
	Mode                    string `json:"mode,omitempty"`
	AllowFallback           bool   `json:"allow_fallback,omitempty"`
	IncludeCommandArguments bool   `json:"include_command_arguments,omitempty"`
	IncludeFilePaths        bool   `json:"include_file_paths,omitempty"`
	IncludeNetworkAddresses bool   `json:"include_network_addresses,omitempty"`
}

// EnhancedRecordingSession identifies the remote-access session being traced.
type EnhancedRecordingSession struct {
	SessionID             string
	Protocol              string
	AgentID               string
	GatewayID             string
	Target                map[string]string
	TargetExecutionMode   string
	CredentialCustodyMode string
	Policy                EnhancedRecordingPolicy
}

// EnhancedEvent is the clean-room normalized event shape emitted by future
// Linux collectors. It intentionally excludes terminal bytes and file contents.
type EnhancedEvent struct {
	EventType             string            `json:"event_type"`
	SessionID             string            `json:"session_id"`
	Protocol              string            `json:"protocol,omitempty"`
	ActorID               string            `json:"actor_id,omitempty"`
	AgentID               string            `json:"agent_id,omitempty"`
	GatewayID             string            `json:"gateway_id,omitempty"`
	Target                map[string]string `json:"target,omitempty"`
	CredentialCustodyMode string            `json:"credential_custody_mode,omitempty"`
	TimestampUnixNano     int64             `json:"timestamp_unix_nano"`
	PID                   int               `json:"pid,omitempty"`
	PPID                  int               `json:"ppid,omitempty"`
	UID                   int               `json:"uid,omitempty"`
	GID                   int               `json:"gid,omitempty"`
	CommandPath           string            `json:"command_path,omitempty"`
	Argv                  []string          `json:"argv,omitempty"`
	CWD                   string            `json:"cwd,omitempty"`
	ExitStatus            *int              `json:"exit_status,omitempty"`
	FilePath              string            `json:"file_path,omitempty"`
	FileOperation         string            `json:"file_operation,omitempty"`
	NetworkProtocol       string            `json:"network_protocol,omitempty"`
	SourceAddress         string            `json:"source_address,omitempty"`
	SourcePort            int               `json:"source_port,omitempty"`
	DestinationAddress    string            `json:"destination_address,omitempty"`
	DestinationPort       int               `json:"destination_port,omitempty"`
	Result                string            `json:"result,omitempty"`
	DroppedEvents         uint64            `json:"dropped_events,omitempty"`
	Metadata              map[string]string `json:"metadata,omitempty"`
}

// EnhancedRecording is a running collector instance scoped to one session.
type EnhancedRecording interface {
	Events() <-chan EnhancedEvent
	Stop(context.Context) error
}

// EnhancedRecorder starts a collector for a single remote-access session.
type EnhancedRecorder interface {
	Start(context.Context, EnhancedRecordingSession) (EnhancedRecording, error)
}

func enhancedPolicyFromFrame(frame Frame) EnhancedRecordingPolicy {
	var payload struct {
		EnhancedRecordingPolicy EnhancedRecordingPolicy `json:"enhanced_recording_policy,omitempty"`
	}
	if len(frame.Data) == 0 {
		return EnhancedRecordingPolicy{}
	}
	if err := json.Unmarshal(frame.Data, &payload); err != nil {
		return EnhancedRecordingPolicy{}
	}
	return payload.EnhancedRecordingPolicy
}

func enhancedRecordingEnabled(policy EnhancedRecordingPolicy) bool {
	if policy.Enabled || policy.Required {
		return true
	}
	switch strings.TrimSpace(strings.ToLower(policy.Mode)) {
	case "bpf", "enhanced", "command", enhancedPolicyModeHostEvents:
		return true
	default:
		return false
	}
}

func enhancedSessionFromFrame(frame Frame, policy EnhancedRecordingPolicy) EnhancedRecordingSession {
	var payload struct {
		AgentID          string            `json:"agent_id,omitempty"`
		GatewayID        string            `json:"gateway_id,omitempty"`
		Target           map[string]any    `json:"target,omitempty"`
		CredentialMode   string            `json:"credential_mode,omitempty"`
		CredentialPolicy string            `json:"credential_custody_mode,omitempty"`
		TargetExecMode   string            `json:"target_execution_mode,omitempty"`
		ManagedTarget    bool              `json:"managed_target,omitempty"`
		Metadata         map[string]string `json:"metadata,omitempty"`
	}
	_ = json.Unmarshal(frame.Data, &payload)

	agentID := payload.AgentID
	if agentID == "" && frame.Metadata != nil {
		agentID = frame.Metadata["agent_id"]
	}

	mode := payload.CredentialMode
	if mode == "" {
		mode = payload.CredentialPolicy
	}

	target := stringifyTarget(payload.Target)
	targetExecutionMode := firstNonEmpty(payload.TargetExecMode, payload.Metadata["target_execution_mode"], target["execution_mode"])
	if payload.ManagedTarget || target["managed_target"] == enhancedMetadataTrue {
		targetExecutionMode = EnhancedExecutionManagedTarget
	}

	return EnhancedRecordingSession{
		SessionID:             frame.SessionID,
		Protocol:              frame.Protocol,
		AgentID:               agentID,
		GatewayID:             payload.GatewayID,
		Target:                target,
		TargetExecutionMode:   targetExecutionMode,
		CredentialCustodyMode: mode,
		Policy:                policy,
	}
}

func validateEnhancedRecordingBoundary(session EnhancedRecordingSession) error {
	if session.Protocol == ProtocolSSH && session.Policy.Required && requiresBPF(session.Policy) &&
		!session.Policy.AllowFallback && session.TargetExecutionMode != EnhancedExecutionManagedTarget {
		return ErrEnhancedRecordingTargetBoundaryRequired
	}

	return nil
}

func normalizeEnhancedEvent(session EnhancedRecordingSession, event EnhancedEvent) EnhancedEvent {
	event.SessionID = session.SessionID
	event.Protocol = firstNonEmpty(event.Protocol, session.Protocol)
	event.AgentID = firstNonEmpty(event.AgentID, session.AgentID)
	event.GatewayID = firstNonEmpty(event.GatewayID, session.GatewayID)
	event.CredentialCustodyMode = firstNonEmpty(event.CredentialCustodyMode, session.CredentialCustodyMode)
	if event.Target == nil {
		event.Target = copyStringMap(session.Target)
	}
	if event.TimestampUnixNano == 0 {
		event.TimestampUnixNano = time.Now().UnixNano()
	}

	switch event.EventType {
	case EnhancedEventCommand:
		if !session.Policy.IncludeCommandArguments {
			event.Argv = nil
		} else {
			event.Argv = redactArgs(event.Argv)
		}
	case EnhancedEventFile:
		if !session.Policy.IncludeFilePaths {
			event.FilePath = ""
		}
	case EnhancedEventNetwork:
		if !session.Policy.IncludeNetworkAddresses {
			event.SourceAddress = ""
			event.SourcePort = 0
			event.DestinationAddress = ""
			event.DestinationPort = 0
		}
	case EnhancedEventLoss:
		// Loss events carry counters only.
	default:
		event.EventType = "unknown"
	}

	event.Metadata = redactMetadata(event.Metadata)

	return event
}

func enhancedEventFrame(session EnhancedRecordingSession, event EnhancedEvent) Frame {
	normalized := normalizeEnhancedEvent(session, event)
	data, err := json.Marshal(normalized)
	if err != nil {
		data = []byte(`{"event_type":"unknown"}`)
	}

	return Frame{
		SessionID: session.SessionID,
		Protocol:  session.Protocol,
		FrameType: FrameTypeEnhancedEvent,
		Data:      data,
		Timestamp: nowUnix(),
	}
}

func stringifyTarget(target map[string]any) map[string]string {
	if len(target) == 0 {
		return nil
	}
	out := make(map[string]string, len(target))
	for key, value := range target {
		switch typed := value.(type) {
		case string:
			if typed != "" {
				out[key] = typed
			}
		case float64:
			out[key] = strconv.FormatFloat(typed, 'f', -1, 64)
		case bool:
			if typed {
				out[key] = enhancedMetadataTrue
			} else {
				out[key] = enhancedMetadataFalse
			}
		}
	}
	return out
}

func redactArgs(args []string) []string {
	if len(args) == 0 {
		return nil
	}
	out := append([]string(nil), args...)
	for index, arg := range out {
		if sensitiveToken(arg) {
			out[index] = enhancedMetadataRedacted
		}
	}
	return out
}

func redactMetadata(metadata map[string]string) map[string]string {
	if len(metadata) == 0 {
		return nil
	}
	out := make(map[string]string, len(metadata))
	for key, value := range metadata {
		if sensitiveToken(key) || sensitiveToken(value) {
			out[key] = enhancedMetadataRedacted
		} else {
			out[key] = value
		}
	}
	return out
}

func sensitiveToken(value string) bool {
	normalized := strings.ToLower(value)
	return strings.Contains(normalized, "password") ||
		strings.Contains(normalized, "passwd") ||
		strings.Contains(normalized, "passphrase") ||
		strings.Contains(normalized, "private_key") ||
		strings.Contains(normalized, "private key") ||
		strings.Contains(normalized, "file_content") ||
		strings.Contains(normalized, "file contents") ||
		strings.Contains(normalized, "secret") ||
		strings.Contains(normalized, "terminal") ||
		strings.Contains(normalized, "token")
}

func copyStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func requiresBPF(policy EnhancedRecordingPolicy) bool {
	mode := strings.TrimSpace(strings.ToLower(policy.Mode))
	return mode == "bpf"
}
