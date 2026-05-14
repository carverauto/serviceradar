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
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

const (
	DesktopCredentialModeDomainDelegation = "domain_delegation"
	DesktopCredentialModeMemoryUser       = "memory_user"
	DesktopCredentialModeSmartCard        = "smart_card"
	DesktopCredentialModeBrokeredSecret   = "brokered_secret"

	DesktopTLSModeVerify     = "verify"
	DesktopTLSModePinnedCA   = "pinned_ca"
	DesktopTLSModeInsecure   = "insecure"
	DesktopTLSModeSystem     = "system"
	DesktopTLSModeTOFU       = "tofu"
	DesktopDefaultTLSPolicy  = DesktopTLSModeVerify
	DesktopDefaultRDPPort    = 3389
	DesktopDefaultMaxWidth   = 1920
	DesktopDefaultMaxHeight  = 1080
	DesktopDefaultFrameRate  = 30
	DesktopDefaultBitrateBPS = 8_000_000
	DesktopDefaultIdleSec    = 900
	DesktopDefaultTTLSec     = 3600
	DesktopMaxWidth          = 7680
	DesktopMaxHeight         = 4320
	DesktopMaxFrameRate      = 60
	DesktopMaxBitrateBPS     = 100_000_000
	DesktopMaxFrameData      = 1_048_576

	DesktopClipboardModeDisabled      = "disabled"
	DesktopClipboardModeTextToRemote  = "text_to_remote"
	DesktopClipboardModeTextToBrowser = "text_to_browser"
	DesktopClipboardModeTextBoth      = "text_bidirectional"

	DesktopFrameTypeUpdate     = "desktop.update"
	DesktopFrameTypeInput      = "desktop.input"
	DesktopFrameTypeResize     = "desktop.resize"
	DesktopFrameTypeClipboard  = "desktop.clipboard"
	DesktopFrameTypeQuality    = "desktop.quality"
	DesktopFrameTypeDisconnect = "desktop.disconnect"

	DesktopInputKindKey     = "key"
	DesktopInputKindPointer = "pointer"
	DesktopInputKindFocus   = "focus"
)

var (
	ErrInvalidDesktopTarget = errors.New("invalid desktop target")
	ErrInvalidDesktopFrame  = errors.New("invalid desktop frame")
)

// DesktopOpenPayload is the agent-side open-frame contract for graphical
// desktop protocols. It contains trusted target policy compiled by core, not
// browser-selected upstream settings.
type DesktopOpenPayload struct {
	Schema          string                  `json:"schema,omitempty"`
	Target          DesktopTarget           `json:"target"`
	CredentialGrant *DesktopCredentialGrant `json:"credential_grant,omitempty"`
	Metadata        map[string]string       `json:"metadata,omitempty"`
}

// DesktopTarget describes one registered desktop target and its immutable
// per-session policy snapshot.
type DesktopTarget struct {
	TargetID         string                   `json:"target_id"`
	DisplayName      string                   `json:"display_name,omitempty"`
	DeviceUID        string                   `json:"device_uid,omitempty"`
	Protocol         string                   `json:"protocol"`
	Route            DesktopRoute             `json:"route"`
	Upstream         DesktopUpstream          `json:"upstream"`
	TLS              DesktopTLSPolicy         `json:"tls"`
	Credential       DesktopCredentialPolicy  `json:"credential"`
	Screen           DesktopScreenPolicy      `json:"screen"`
	Redirection      DesktopRedirectionPolicy `json:"redirection"`
	ApprovalRequired bool                     `json:"approval_required,omitempty"`
	Recording        DesktopRecordingPolicy   `json:"recording"`
	Metadata         map[string]string        `json:"metadata,omitempty"`
}

type DesktopRoute struct {
	SelectedAgentID string   `json:"selected_agent_id"`
	SelectedGateway string   `json:"selected_gateway_id,omitempty"`
	AllowedAgentIDs []string `json:"allowed_agent_ids,omitempty"`
}

type DesktopUpstream struct {
	Host string `json:"host"`
	Port uint32 `json:"port"`
}

type DesktopTLSPolicy struct {
	Mode       string `json:"mode"`
	CABundleID string `json:"ca_bundle_id,omitempty"`
	ServerName string `json:"server_name,omitempty"`
}

type DesktopCredentialPolicy struct {
	Mode                string   `json:"mode"`
	AllowedPrincipals   []string `json:"allowed_principals,omitempty"`
	CredentialSecretRef string   `json:"credential_secret_ref,omitempty"`
}

type DesktopCredentialGrant struct {
	Mode                string `json:"mode"`
	Username            string `json:"username,omitempty"`
	Password            string `json:"password,omitempty"`
	CredentialSecretRef string `json:"credential_secret_ref,omitempty"`
	ActorID             string `json:"actor_id,omitempty"`
	SessionID           string `json:"session_id,omitempty"`
	TargetID            string `json:"target_id,omitempty"`
	RouteID             string `json:"route_id,omitempty"`
	ExpiresUnix         int64  `json:"expires_unix,omitempty"`
}

type DesktopScreenPolicy struct {
	MaxWidth    uint32 `json:"max_width"`
	MaxHeight   uint32 `json:"max_height"`
	ColorDepth  uint32 `json:"color_depth,omitempty"`
	FrameRate   uint32 `json:"frame_rate"`
	BitrateBPS  uint32 `json:"bitrate_bps"`
	IdleSeconds uint32 `json:"idle_seconds"`
	TTLSeconds  uint32 `json:"ttl_seconds"`
}

type DesktopRedirectionPolicy struct {
	ClipboardMode string `json:"clipboard_mode"`
	Drive         bool   `json:"drive,omitempty"`
	Printer       bool   `json:"printer,omitempty"`
	Audio         bool   `json:"audio,omitempty"`
	SmartCard     bool   `json:"smart_card,omitempty"`
	FileCopy      bool   `json:"file_copy,omitempty"`
}

type DesktopRecordingPolicy struct {
	MetadataEnabled  bool `json:"metadata_enabled"`
	ScreenEnabled    bool `json:"screen_enabled,omitempty"`
	ClipboardEnabled bool `json:"clipboard_enabled,omitempty"`
	FileEnabled      bool `json:"file_enabled,omitempty"`
	AudioEnabled     bool `json:"audio_enabled,omitempty"`
}

// DesktopFrame is the protocol-neutral graphical frame contract used by RDP
// and future desktop adapters. It is intentionally separate from terminal PTY
// byte frames.
type DesktopFrame struct {
	SessionID string             `json:"session_id"`
	Protocol  string             `json:"protocol"`
	FrameType string             `json:"frame_type"`
	Width     uint32             `json:"width,omitempty"`
	Height    uint32             `json:"height,omitempty"`
	Encoding  string             `json:"encoding,omitempty"`
	Data      []byte             `json:"data,omitempty"`
	Input     *DesktopInputEvent `json:"input,omitempty"`
	Quality   *DesktopQuality    `json:"quality,omitempty"`
	Reason    string             `json:"reason,omitempty"`
	Timestamp int64              `json:"timestamp,omitempty"`
	Metadata  map[string]string  `json:"metadata,omitempty"`
}

type DesktopInputEvent struct {
	Kind    string `json:"kind"`
	Key     string `json:"key,omitempty"`
	Down    bool   `json:"down,omitempty"`
	Button  string `json:"button,omitempty"`
	X       uint32 `json:"x,omitempty"`
	Y       uint32 `json:"y,omitempty"`
	Focused bool   `json:"focused,omitempty"`
}

type DesktopQuality struct {
	MaxFrameRate uint32 `json:"max_frame_rate,omitempty"`
	MaxBitrate   uint32 `json:"max_bitrate_bps,omitempty"`
	Width        uint32 `json:"width,omitempty"`
	Height       uint32 `json:"height,omitempty"`
}

// DecodeDesktopOpenPayload decodes and validates a trusted desktop open-frame
// payload before an agent adapter dials the target.
func DecodeDesktopOpenPayload(data []byte) (DesktopOpenPayload, error) {
	var payload DesktopOpenPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return payload, fmt.Errorf("%w: decode open payload: %w", ErrInvalidDesktopTarget, err)
	}

	target, err := NormalizeDesktopTarget(payload.Target)
	if err != nil {
		return payload, err
	}
	payload.Target = target

	if payload.CredentialGrant != nil {
		grant, err := NormalizeDesktopCredentialGrant(*payload.CredentialGrant, target)
		if err != nil {
			return payload, err
		}
		payload.CredentialGrant = &grant
	}

	return payload, nil
}

// DecodeDesktopOpenFrameForAgent decodes a trusted desktop open frame and
// enforces that the selected route is bound to the local agent before an
// adapter dials the target.
func DecodeDesktopOpenFrameForAgent(frame Frame, localAgentID string) (DesktopOpenPayload, error) {
	var payload DesktopOpenPayload

	localAgentID = strings.TrimSpace(localAgentID)
	if frame.SessionID == "" {
		return payload, fmt.Errorf("%w: missing session binding", ErrInvalidDesktopTarget)
	}
	if localAgentID == "" {
		return payload, fmt.Errorf("%w: missing local agent binding", ErrInvalidDesktopTarget)
	}
	if frame.FrameType != FrameTypeOpen {
		return payload, fmt.Errorf("%w: expected open frame", ErrInvalidDesktopTarget)
	}
	if !validDesktopProtocol(frame.Protocol) {
		return payload, fmt.Errorf("%w: unsupported protocol", ErrInvalidDesktopTarget)
	}

	payload, err := DecodeDesktopOpenPayload(frame.Data)
	if err != nil {
		return payload, err
	}
	if payload.Target.Route.SelectedAgentID != localAgentID {
		return payload, fmt.Errorf("%w: selected route does not match local agent", ErrInvalidDesktopTarget)
	}
	if payload.CredentialGrant != nil &&
		payload.CredentialGrant.SessionID != "" &&
		payload.CredentialGrant.SessionID != frame.SessionID {
		return payload, fmt.Errorf("%w: credential grant session mismatch", ErrInvalidDesktopTarget)
	}

	return payload, nil
}

// EncodeDesktopFramePayload validates and serializes a typed desktop frame for
// transport inside the existing ConsoleFrame data field.
func EncodeDesktopFramePayload(frame DesktopFrame, policy DesktopScreenPolicy) ([]byte, error) {
	if err := ValidateDesktopFrame(frame, policy); err != nil {
		return nil, err
	}

	data, err := json.Marshal(frame)
	if err != nil {
		return nil, fmt.Errorf("%w: encode frame payload: %w", ErrInvalidDesktopFrame, err)
	}

	return data, nil
}

// DecodeDesktopFramePayload decodes and validates a typed desktop frame carried
// inside the existing ConsoleFrame data field.
func DecodeDesktopFramePayload(data []byte, policy DesktopScreenPolicy) (DesktopFrame, error) {
	var frame DesktopFrame
	if err := json.Unmarshal(data, &frame); err != nil {
		return frame, fmt.Errorf("%w: decode frame payload: %w", ErrInvalidDesktopFrame, err)
	}
	if err := ValidateDesktopFrame(frame, policy); err != nil {
		return frame, err
	}

	return frame, nil
}

// DecodeDesktopFramePayloadForSession decodes a typed desktop frame and rejects
// frames that are not bound to the expected remote-access session.
func DecodeDesktopFramePayloadForSession(
	data []byte,
	policy DesktopScreenPolicy,
	sessionID string,
) (DesktopFrame, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return DesktopFrame{}, fmt.Errorf("%w: missing session binding", ErrInvalidDesktopFrame)
	}

	frame, err := DecodeDesktopFramePayload(data, policy)
	if err != nil {
		return frame, err
	}
	if frame.SessionID != sessionID {
		return frame, fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopFrame)
	}

	return frame, nil
}

// NormalizeDesktopTarget applies secure defaults and validates the registered
// desktop target policy snapshot.
func NormalizeDesktopTarget(target DesktopTarget) (DesktopTarget, error) {
	target.TargetID = strings.TrimSpace(target.TargetID)
	target.Protocol = strings.TrimSpace(target.Protocol)
	target.Route.SelectedAgentID = strings.TrimSpace(target.Route.SelectedAgentID)
	target.Route.SelectedGateway = strings.TrimSpace(target.Route.SelectedGateway)
	target.Upstream.Host = strings.TrimSpace(target.Upstream.Host)
	target.TLS.Mode = strings.TrimSpace(target.TLS.Mode)
	target.TLS.CABundleID = strings.TrimSpace(target.TLS.CABundleID)
	target.TLS.ServerName = strings.TrimSpace(target.TLS.ServerName)
	target.Credential.Mode = strings.TrimSpace(target.Credential.Mode)
	target.Credential.CredentialSecretRef = strings.TrimSpace(target.Credential.CredentialSecretRef)

	if target.Protocol == "" {
		target.Protocol = ProtocolRDP
	}
	if target.Upstream.Port == 0 && target.Protocol == ProtocolRDP {
		target.Upstream.Port = DesktopDefaultRDPPort
	}
	if target.TLS.Mode == "" {
		target.TLS.Mode = DesktopDefaultTLSPolicy
	}
	target.Screen = normalizeDesktopScreenPolicy(target.Screen)
	target.Redirection = normalizeDesktopRedirectionPolicy(target.Redirection)
	if !target.Recording.MetadataEnabled &&
		!target.Recording.ScreenEnabled &&
		!target.Recording.ClipboardEnabled &&
		!target.Recording.FileEnabled &&
		!target.Recording.AudioEnabled {
		target.Recording.MetadataEnabled = true
	}

	if err := validateDesktopTarget(target); err != nil {
		return target, err
	}

	return target, nil
}

func NormalizeDesktopCredentialGrant(
	grant DesktopCredentialGrant,
	target DesktopTarget,
) (DesktopCredentialGrant, error) {
	grant.Mode = strings.TrimSpace(grant.Mode)
	grant.Username = strings.TrimSpace(grant.Username)
	grant.CredentialSecretRef = strings.TrimSpace(grant.CredentialSecretRef)
	grant.ActorID = strings.TrimSpace(grant.ActorID)
	grant.SessionID = strings.TrimSpace(grant.SessionID)
	grant.TargetID = strings.TrimSpace(grant.TargetID)
	grant.RouteID = strings.TrimSpace(grant.RouteID)

	if grant.Mode == "" {
		grant.Mode = target.Credential.Mode
	}
	if grant.Mode != target.Credential.Mode {
		return grant, fmt.Errorf("%w: credential grant mode does not match target policy", ErrInvalidDesktopTarget)
	}
	if grant.TargetID == "" {
		if grant.Mode == DesktopCredentialModeBrokeredSecret {
			return grant, fmt.Errorf("%w: brokered credential grant requires target binding", ErrInvalidDesktopTarget)
		}
		grant.TargetID = target.TargetID
	}
	if grant.TargetID != target.TargetID {
		return grant, fmt.Errorf("%w: credential grant target mismatch", ErrInvalidDesktopTarget)
	}

	switch grant.Mode {
	case DesktopCredentialModeBrokeredSecret:
		if grant.CredentialSecretRef == "" {
			return grant, fmt.Errorf("%w: brokered credential grant requires secret reference", ErrInvalidDesktopTarget)
		}
		if grant.CredentialSecretRef != target.Credential.CredentialSecretRef {
			return grant, fmt.Errorf("%w: brokered credential grant secret mismatch", ErrInvalidDesktopTarget)
		}
		if grant.Password != "" {
			return grant, fmt.Errorf("%w: brokered credential grant must not include password", ErrInvalidDesktopTarget)
		}
		if grant.ActorID == "" || grant.SessionID == "" || grant.RouteID == "" || grant.ExpiresUnix <= 0 {
			return grant, fmt.Errorf("%w: brokered credential grant requires actor, session, route, and ttl binding", ErrInvalidDesktopTarget)
		}
	case DesktopCredentialModeMemoryUser:
		if grant.Username == "" || grant.Password == "" {
			return grant, fmt.Errorf("%w: memory user credential grant requires username and password", ErrInvalidDesktopTarget)
		}
	}

	return grant, nil
}

func ValidateDesktopFrame(frame DesktopFrame, policy DesktopScreenPolicy) error {
	return validateDesktopFrame(frame, policy, nil)
}

// ValidateDesktopFrameWithPolicy validates a desktop frame against both screen
// and redirection policy. Use this for any path that accepts clipboard or other
// local resource redirection frames.
func ValidateDesktopFrameWithPolicy(
	frame DesktopFrame,
	policy DesktopScreenPolicy,
	redirection DesktopRedirectionPolicy,
) error {
	return validateDesktopFrame(frame, policy, &redirection)
}

func validateDesktopFrame(
	frame DesktopFrame,
	policy DesktopScreenPolicy,
	redirection *DesktopRedirectionPolicy,
) error {
	if frame.SessionID == "" {
		return fmt.Errorf("%w: missing session id", ErrInvalidDesktopFrame)
	}
	if !validDesktopProtocol(frame.Protocol) {
		return fmt.Errorf("%w: unsupported protocol", ErrInvalidDesktopFrame)
	}

	policy = normalizeDesktopScreenPolicy(policy)
	switch frame.FrameType {
	case DesktopFrameTypeUpdate:
		if frame.Width == 0 || frame.Height == 0 || frame.Width > policy.MaxWidth || frame.Height > policy.MaxHeight {
			return fmt.Errorf("%w: update dimensions exceed policy", ErrInvalidDesktopFrame)
		}
		if len(frame.Data) > DesktopMaxFrameData {
			return fmt.Errorf("%w: update data exceeds maximum", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeResize:
		if frame.Width == 0 || frame.Height == 0 || frame.Width > policy.MaxWidth || frame.Height > policy.MaxHeight {
			return fmt.Errorf("%w: resize dimensions exceed policy", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeInput:
		if frame.Input == nil || !validDesktopInputKind(frame.Input.Kind) {
			return fmt.Errorf("%w: invalid input event", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeClipboard:
		if !desktopClipboardFrameAllowed(redirection) {
			return fmt.Errorf("%w: clipboard redirection disabled", ErrInvalidDesktopFrame)
		}
		if len(frame.Data) > MaxTerminalFrameData {
			return fmt.Errorf("%w: clipboard data exceeds maximum", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeQuality:
		if frame.Quality == nil {
			return fmt.Errorf("%w: missing quality request", ErrInvalidDesktopFrame)
		}
		if frame.Quality.MaxFrameRate > DesktopMaxFrameRate ||
			frame.Quality.MaxBitrate > DesktopMaxBitrateBPS ||
			frame.Quality.Width > policy.MaxWidth ||
			frame.Quality.Height > policy.MaxHeight {
			return fmt.Errorf("%w: quality request exceeds policy", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeDisconnect:
	default:
		return fmt.Errorf("%w: unsupported frame type", ErrInvalidDesktopFrame)
	}

	return nil
}

func desktopClipboardFrameAllowed(redirection *DesktopRedirectionPolicy) bool {
	if redirection == nil {
		return false
	}

	policy := normalizeDesktopRedirectionPolicy(*redirection)

	return policy.ClipboardMode != DesktopClipboardModeDisabled
}

func normalizeDesktopScreenPolicy(policy DesktopScreenPolicy) DesktopScreenPolicy {
	if policy.MaxWidth == 0 {
		policy.MaxWidth = DesktopDefaultMaxWidth
	}
	if policy.MaxHeight == 0 {
		policy.MaxHeight = DesktopDefaultMaxHeight
	}
	if policy.FrameRate == 0 {
		policy.FrameRate = DesktopDefaultFrameRate
	}
	if policy.BitrateBPS == 0 {
		policy.BitrateBPS = DesktopDefaultBitrateBPS
	}
	if policy.IdleSeconds == 0 {
		policy.IdleSeconds = DesktopDefaultIdleSec
	}
	if policy.TTLSeconds == 0 {
		policy.TTLSeconds = DesktopDefaultTTLSec
	}

	return policy
}

func normalizeDesktopRedirectionPolicy(policy DesktopRedirectionPolicy) DesktopRedirectionPolicy {
	policy.ClipboardMode = strings.TrimSpace(policy.ClipboardMode)
	if policy.ClipboardMode == "" {
		policy.ClipboardMode = DesktopClipboardModeDisabled
	}

	return policy
}

func validateDesktopTarget(target DesktopTarget) error {
	if target.TargetID == "" {
		return fmt.Errorf("%w: missing target id", ErrInvalidDesktopTarget)
	}
	if !validDesktopProtocol(target.Protocol) {
		return fmt.Errorf("%w: unsupported protocol", ErrInvalidDesktopTarget)
	}
	if target.Route.SelectedAgentID == "" {
		return fmt.Errorf("%w: missing selected agent", ErrInvalidDesktopTarget)
	}
	if target.Upstream.Host == "" || target.Upstream.Port == 0 || target.Upstream.Port > 65_535 {
		return fmt.Errorf("%w: invalid upstream", ErrInvalidDesktopTarget)
	}
	if !validDesktopTLSMode(target.TLS.Mode) {
		return fmt.Errorf("%w: invalid tls mode", ErrInvalidDesktopTarget)
	}
	if !validDesktopCredentialMode(target.Credential.Mode) {
		return fmt.Errorf("%w: invalid credential mode", ErrInvalidDesktopTarget)
	}
	if target.Credential.Mode == DesktopCredentialModeBrokeredSecret {
		if target.Credential.CredentialSecretRef == "" {
			return fmt.Errorf("%w: brokered secret mode requires secret reference", ErrInvalidDesktopTarget)
		}
		if !target.ApprovalRequired {
			return fmt.Errorf("%w: brokered secret mode requires approval", ErrInvalidDesktopTarget)
		}
	}
	if err := validateDesktopScreenPolicy(target.Screen); err != nil {
		return err
	}
	if !validDesktopClipboardMode(target.Redirection.ClipboardMode) {
		return fmt.Errorf("%w: invalid clipboard mode", ErrInvalidDesktopTarget)
	}

	return nil
}

func validateDesktopScreenPolicy(policy DesktopScreenPolicy) error {
	if policy.MaxWidth == 0 || policy.MaxWidth > DesktopMaxWidth ||
		policy.MaxHeight == 0 || policy.MaxHeight > DesktopMaxHeight ||
		policy.FrameRate == 0 || policy.FrameRate > DesktopMaxFrameRate ||
		policy.BitrateBPS == 0 || policy.BitrateBPS > DesktopMaxBitrateBPS ||
		policy.IdleSeconds == 0 ||
		policy.TTLSeconds == 0 {
		return fmt.Errorf("%w: invalid screen policy", ErrInvalidDesktopTarget)
	}

	return nil
}

func validDesktopProtocol(protocol string) bool {
	return protocol == ProtocolRDP || protocol == ProtocolDesktop
}

func validDesktopTLSMode(mode string) bool {
	switch mode {
	case DesktopTLSModeVerify, DesktopTLSModePinnedCA, DesktopTLSModeInsecure, DesktopTLSModeSystem, DesktopTLSModeTOFU:
		return true
	default:
		return false
	}
}

func validDesktopCredentialMode(mode string) bool {
	switch mode {
	case DesktopCredentialModeDomainDelegation,
		DesktopCredentialModeMemoryUser,
		DesktopCredentialModeSmartCard,
		DesktopCredentialModeBrokeredSecret:
		return true
	default:
		return false
	}
}

func validDesktopClipboardMode(mode string) bool {
	switch mode {
	case DesktopClipboardModeDisabled,
		DesktopClipboardModeTextToRemote,
		DesktopClipboardModeTextToBrowser,
		DesktopClipboardModeTextBoth:
		return true
	default:
		return false
	}
}

func validDesktopInputKind(kind string) bool {
	switch kind {
	case DesktopInputKindKey, DesktopInputKindPointer, DesktopInputKindFocus:
		return true
	default:
		return false
	}
}
