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
	"strconv"
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
	DesktopMaxInputTokenSize = 128
	DesktopMaxAuditReason    = 256

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

	DesktopLifecycleEventOpen    = "desktop.session.open"
	DesktopLifecycleEventReady   = "desktop.session.ready"
	DesktopLifecycleEventClose   = "desktop.session.close"
	DesktopLifecycleEventError   = "desktop.session.error"
	DesktopLifecycleEventRevoked = "desktop.session.revoked"

	DesktopInputKindKey     = "key"
	DesktopInputKindPointer = "pointer"
	DesktopInputKindFocus   = "focus"

	DesktopClipboardDirectionToRemote  = "to_remote"
	DesktopClipboardDirectionToBrowser = "to_browser"
)

var (
	ErrInvalidDesktopTarget  = errors.New("invalid desktop target")
	ErrInvalidDesktopFrame   = errors.New("invalid desktop frame")
	ErrDesktopContentRecord  = errors.New("desktop content recording disabled")
	ErrDesktopQuotaExceeded  = errors.New("desktop quota exceeded")
	ErrDesktopSessionExpired = errors.New("desktop session expired")
	ErrDesktopRouteLost      = errors.New("desktop route lost")
)

const desktopQuotaWindowNanos int64 = 1_000_000_000

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

// DropSensitive clears session credential material from the grant once an
// adapter no longer needs it. Password is string-backed because grants arrive
// over JSON, so this releases references rather than promising allocator-level
// memory scrubbing.
func (grant *DesktopCredentialGrant) DropSensitive() {
	if grant == nil {
		return
	}

	grant.Username = ""
	grant.Password = ""
	grant.CredentialSecretRef = ""
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
	Direction string             `json:"direction,omitempty"`
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

// DesktopFrameQuotaWindow tracks per-second screen update quotas for adapter
// code before the dedicated desktop media stream carries production traffic.
type DesktopFrameQuotaWindow struct {
	policy              DesktopScreenPolicy
	windowStartUnixNano int64
	frameCount          uint32
	bitCount            uint64
}

// DesktopSessionGuard centralizes the per-frame checks an adapter must perform
// while a desktop session is active. It keeps route binding, lifetime,
// redirection policy, and update-frame quotas on one path so adapter code does
// not accidentally validate only part of the session contract.
type DesktopSessionGuard struct {
	sessionID        string
	target           DesktopTarget
	startUnix        int64
	lastActivityUnix int64
	quota            DesktopFrameQuotaWindow
}

func NewDesktopFrameQuotaWindow(policy DesktopScreenPolicy) DesktopFrameQuotaWindow {
	return DesktopFrameQuotaWindow{policy: normalizeDesktopScreenPolicy(policy)}
}

func NewDesktopSessionGuard(sessionID string, target DesktopTarget, startUnix int64) (DesktopSessionGuard, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return DesktopSessionGuard{}, fmt.Errorf("%w: missing session binding", ErrInvalidDesktopFrame)
	}
	if startUnix <= 0 {
		return DesktopSessionGuard{}, fmt.Errorf("%w: invalid session timestamp", ErrInvalidDesktopFrame)
	}

	target, err := NormalizeDesktopTarget(target)
	if err != nil {
		return DesktopSessionGuard{}, err
	}

	return DesktopSessionGuard{
		sessionID:        sessionID,
		target:           target,
		startUnix:        startUnix,
		lastActivityUnix: startUnix,
		quota:            NewDesktopFrameQuotaWindow(target.Screen),
	}, nil
}

func (g *DesktopSessionGuard) SessionID() string {
	if g == nil {
		return ""
	}

	return g.sessionID
}

func (g *DesktopSessionGuard) Target() DesktopTarget {
	if g == nil {
		return DesktopTarget{}
	}

	return g.target
}

func (g *DesktopSessionGuard) LastActivityUnix() int64 {
	if g == nil {
		return 0
	}

	return g.lastActivityUnix
}

// ValidateFrame applies the current session guard before an adapter consumes or
// emits a desktop frame. Accepted frames update last-activity time after all
// validation and quota checks succeed.
func (g *DesktopSessionGuard) ValidateFrame(
	frame DesktopFrame,
	localAgentID string,
	currentGatewayID string,
	nowUnix int64,
	nowUnixNano int64,
) error {
	if g == nil {
		return fmt.Errorf("%w: missing session guard", ErrInvalidDesktopFrame)
	}
	if frame.SessionID != g.sessionID {
		return fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopFrame)
	}
	if err := validateDesktopRouteBindingNormalized(g.target, localAgentID, currentGatewayID); err != nil {
		return err
	}
	if err := ValidateDesktopSessionLifetime(g.target.Screen, g.startUnix, g.lastActivityUnix, nowUnix); err != nil {
		return err
	}
	if err := ValidateDesktopFrameWithPolicy(frame, g.target.Screen, g.target.Redirection); err != nil {
		return err
	}
	if err := g.quota.Consume(frame, nowUnixNano); err != nil {
		return err
	}

	g.lastActivityUnix = nowUnix

	return nil
}

// ValidateContentRecording checks whether retaining the sensitive content from
// an already accepted frame is allowed by this session's recording policy.
// Metadata-only audit paths do not need this check; screen pixels and clipboard
// bytes must pass it before being persisted or exported.
func (g *DesktopSessionGuard) ValidateContentRecording(frame DesktopFrame) error {
	if g == nil {
		return fmt.Errorf("%w: missing session guard", ErrInvalidDesktopFrame)
	}
	if frame.SessionID != g.sessionID {
		return fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopFrame)
	}

	return ValidateDesktopContentRecording(frame, g.target.Recording)
}

// Consume applies frame-rate and bitrate quotas to desktop update frames.
// Non-screen frames are ignored here and still use their normal validators.
func (w *DesktopFrameQuotaWindow) Consume(frame DesktopFrame, nowUnixNano int64) error {
	if frame.FrameType != DesktopFrameTypeUpdate {
		return nil
	}
	if nowUnixNano <= 0 {
		return fmt.Errorf("%w: missing quota timestamp", ErrInvalidDesktopFrame)
	}

	if w.policy.FrameRate == 0 || w.policy.BitrateBPS == 0 {
		w.policy = normalizeDesktopScreenPolicy(w.policy)
	}
	if w.windowStartUnixNano == 0 ||
		nowUnixNano < w.windowStartUnixNano ||
		nowUnixNano-w.windowStartUnixNano >= desktopQuotaWindowNanos {
		w.windowStartUnixNano = nowUnixNano
		w.frameCount = 0
		w.bitCount = 0
	}

	if w.frameCount >= w.policy.FrameRate {
		return fmt.Errorf("%w: frame rate", ErrDesktopQuotaExceeded)
	}

	frameBits := uint64(len(frame.Data)) * 8
	maxBits := uint64(w.policy.BitrateBPS)
	if frameBits > maxBits || w.bitCount > maxBits-frameBits {
		return fmt.Errorf("%w: bitrate", ErrDesktopQuotaExceeded)
	}

	w.frameCount++
	w.bitCount += frameBits

	return nil
}

// ValidateDesktopSessionLifetime enforces the idle and absolute TTL policy for
// an adapter session. Timestamps are Unix seconds; callers should update
// lastActivityUnix whenever user input, screen traffic, or explicit heartbeat
// activity is accepted for the session.
func ValidateDesktopSessionLifetime(
	policy DesktopScreenPolicy,
	startUnix int64,
	lastActivityUnix int64,
	nowUnix int64,
) error {
	if startUnix <= 0 || nowUnix <= 0 {
		return fmt.Errorf("%w: invalid session timestamp", ErrInvalidDesktopFrame)
	}
	if lastActivityUnix <= 0 {
		lastActivityUnix = startUnix
	}

	policy = normalizeDesktopScreenPolicy(policy)
	if nowUnix < startUnix || nowUnix < lastActivityUnix {
		return fmt.Errorf("%w: clock moved backwards", ErrInvalidDesktopFrame)
	}
	if nowUnix-startUnix >= int64(policy.TTLSeconds) {
		return fmt.Errorf("%w: ttl", ErrDesktopSessionExpired)
	}
	if nowUnix-lastActivityUnix >= int64(policy.IdleSeconds) {
		return fmt.Errorf("%w: idle", ErrDesktopSessionExpired)
	}

	return nil
}

// ValidateDesktopRouteBinding verifies that a still-running desktop session is
// on the selected agent and, when supplied, selected gateway route.
func ValidateDesktopRouteBinding(target DesktopTarget, localAgentID string, currentGatewayID string) error {
	target, err := NormalizeDesktopTarget(target)
	if err != nil {
		return err
	}

	return validateDesktopRouteBindingNormalized(target, localAgentID, currentGatewayID)
}

func validateDesktopRouteBindingNormalized(target DesktopTarget, localAgentID string, currentGatewayID string) error {
	localAgentID = strings.TrimSpace(localAgentID)
	currentGatewayID = strings.TrimSpace(currentGatewayID)
	if localAgentID == "" {
		return fmt.Errorf("%w: missing local agent binding", ErrInvalidDesktopTarget)
	}
	if target.Route.SelectedAgentID != localAgentID {
		return fmt.Errorf("%w: selected agent changed", ErrDesktopRouteLost)
	}
	if currentGatewayID != "" &&
		target.Route.SelectedGateway != "" &&
		target.Route.SelectedGateway != currentGatewayID {
		return fmt.Errorf("%w: selected gateway changed", ErrDesktopRouteLost)
	}

	return nil
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
	if err := ValidateDesktopRouteBinding(payload.Target, localAgentID, ""); err != nil {
		return payload, err
	}
	if payload.CredentialGrant != nil &&
		payload.CredentialGrant.SessionID != "" &&
		payload.CredentialGrant.SessionID != frame.SessionID {
		return payload, fmt.Errorf("%w: credential grant session mismatch", ErrInvalidDesktopTarget)
	}

	return payload, nil
}

// DesktopAuditMetadata returns metadata that is safe to persist for desktop
// session audit/recording records. It intentionally omits usernames, passwords,
// credential secret references, and caller-supplied metadata maps.
func DesktopAuditMetadata(payload DesktopOpenPayload) map[string]string {
	target := payload.Target
	credentialMode := target.Credential.Mode
	if payload.CredentialGrant != nil && payload.CredentialGrant.Mode != "" {
		credentialMode = payload.CredentialGrant.Mode
	}

	return map[string]string{
		"protocol":                       target.Protocol,
		"target_id":                      target.TargetID,
		"device_uid":                     target.DeviceUID,
		"selected_agent_id":              target.Route.SelectedAgentID,
		"selected_gateway_id":            target.Route.SelectedGateway,
		"upstream_host":                  target.Upstream.Host,
		"upstream_port":                  strconv.FormatUint(uint64(target.Upstream.Port), 10),
		"tls_mode":                       target.TLS.Mode,
		"tls_ca_bundle_id":               target.TLS.CABundleID,
		"tls_server_name":                target.TLS.ServerName,
		"credential_mode":                credentialMode,
		"screen_max_width":               strconv.FormatUint(uint64(target.Screen.MaxWidth), 10),
		"screen_max_height":              strconv.FormatUint(uint64(target.Screen.MaxHeight), 10),
		"screen_frame_rate":              strconv.FormatUint(uint64(target.Screen.FrameRate), 10),
		"screen_bitrate_bps":             strconv.FormatUint(uint64(target.Screen.BitrateBPS), 10),
		"screen_idle_seconds":            strconv.FormatUint(uint64(target.Screen.IdleSeconds), 10),
		"screen_ttl_seconds":             strconv.FormatUint(uint64(target.Screen.TTLSeconds), 10),
		"redirection_clipboard_mode":     target.Redirection.ClipboardMode,
		"redirection_drive":              strconv.FormatBool(target.Redirection.Drive),
		"redirection_printer":            strconv.FormatBool(target.Redirection.Printer),
		"redirection_audio":              strconv.FormatBool(target.Redirection.Audio),
		"redirection_smart_card":         strconv.FormatBool(target.Redirection.SmartCard),
		"redirection_file_copy":          strconv.FormatBool(target.Redirection.FileCopy),
		"approval_required":              strconv.FormatBool(target.ApprovalRequired),
		"recording_metadata_enabled":     strconv.FormatBool(target.Recording.MetadataEnabled),
		"recording_screen_enabled":       strconv.FormatBool(target.Recording.ScreenEnabled),
		"recording_clipboard_enabled":    strconv.FormatBool(target.Recording.ClipboardEnabled),
		"recording_file_enabled":         strconv.FormatBool(target.Recording.FileEnabled),
		"recording_audio_enabled":        strconv.FormatBool(target.Recording.AudioEnabled),
		"credential_grant_expires_unix":  desktopCredentialGrantExpiresUnix(payload.CredentialGrant),
		"credential_grant_actor_bound":   strconv.FormatBool(payload.CredentialGrant != nil && payload.CredentialGrant.ActorID != ""),
		"credential_grant_session_bound": strconv.FormatBool(payload.CredentialGrant != nil && payload.CredentialGrant.SessionID != ""),
		"credential_grant_target_bound":  strconv.FormatBool(payload.CredentialGrant != nil && payload.CredentialGrant.TargetID != ""),
		"credential_grant_route_bound":   strconv.FormatBool(payload.CredentialGrant != nil && payload.CredentialGrant.RouteID != ""),
	}
}

func desktopCredentialGrantExpiresUnix(grant *DesktopCredentialGrant) string {
	if grant == nil || grant.ExpiresUnix == 0 {
		return ""
	}

	return strconv.FormatInt(grant.ExpiresUnix, 10)
}

// DesktopLifecycleAuditMetadata returns safe metadata for desktop session
// lifecycle records. It includes target/policy posture plus a fixed event type
// and capped single-line outcome, but it omits credential material and
// caller-supplied metadata.
func DesktopLifecycleAuditMetadata(
	payload DesktopOpenPayload,
	eventType string,
	timestampUnix int64,
	outcome string,
) (map[string]string, error) {
	if !validDesktopLifecycleEventType(eventType) {
		return nil, fmt.Errorf("%w: unsupported lifecycle event type", ErrInvalidDesktopFrame)
	}
	if timestampUnix <= 0 {
		return nil, fmt.Errorf("%w: missing lifecycle timestamp", ErrInvalidDesktopFrame)
	}

	metadata := DesktopAuditMetadata(payload)
	normalizedOutcome, truncated := normalizeDesktopAuditReason(outcome, DesktopMaxAuditReason)
	metadata["event_type"] = eventType
	metadata["event_timestamp_unix"] = strconv.FormatInt(timestampUnix, 10)
	metadata["event_outcome"] = normalizedOutcome
	metadata["event_outcome_truncated"] = strconv.FormatBool(truncated)

	return metadata, nil
}

// DesktopFrameAuditMetadata returns frame metadata suitable for audit and
// recording records without retaining screen pixels, clipboard data, key names,
// button names, or other frame payload contents.
func DesktopFrameAuditMetadata(frame DesktopFrame) map[string]string {
	metadata := map[string]string{
		"session_id":     frame.SessionID,
		"protocol":       frame.Protocol,
		"frame_type":     frame.FrameType,
		"width":          strconv.FormatUint(uint64(frame.Width), 10),
		"height":         strconv.FormatUint(uint64(frame.Height), 10),
		"encoding":       frame.Encoding,
		"payload_bytes":  strconv.Itoa(len(frame.Data)),
		"direction":      frame.Direction,
		"timestamp_unix": strconv.FormatInt(frame.Timestamp, 10),
		"has_input":      strconv.FormatBool(frame.Input != nil),
		"has_quality":    strconv.FormatBool(frame.Quality != nil),
	}
	if frame.Input != nil {
		metadata["input_kind"] = frame.Input.Kind
	}
	if frame.Quality != nil {
		metadata["quality_max_frame_rate"] = strconv.FormatUint(uint64(frame.Quality.MaxFrameRate), 10)
		metadata["quality_max_bitrate_bps"] = strconv.FormatUint(uint64(frame.Quality.MaxBitrate), 10)
		metadata["quality_width"] = strconv.FormatUint(uint64(frame.Quality.Width), 10)
		metadata["quality_height"] = strconv.FormatUint(uint64(frame.Quality.Height), 10)
	}

	return metadata
}

// DesktopTerminationAuditMetadata returns safe metadata for desktop close/error
// outcomes. It includes a capped, single-line reason while keeping generic frame
// audit metadata free of close reasons by default.
func DesktopTerminationAuditMetadata(frame DesktopFrame) map[string]string {
	metadata := DesktopFrameAuditMetadata(frame)
	reason, truncated := normalizeDesktopAuditReason(frame.Reason, DesktopMaxAuditReason)
	metadata["termination_reason"] = reason
	metadata["termination_reason_truncated"] = strconv.FormatBool(truncated)

	return metadata
}

func normalizeDesktopAuditReason(reason string, maxBytes int) (string, bool) {
	reason = strings.TrimSpace(reason)
	if reason == "" || maxBytes <= 0 {
		return "", len(reason) > 0
	}

	var out strings.Builder
	truncated := false

	for _, r := range reason {
		if r < ' ' || r == 0x7f {
			r = ' '
		}

		next := string(r)
		if out.Len()+len(next) > maxBytes {
			truncated = true
			break
		}
		out.WriteString(next)
	}

	return strings.TrimSpace(out.String()), truncated
}

// ValidateDesktopContentRecording returns nil only when policy explicitly
// allows retaining the content represented by the frame.
func ValidateDesktopContentRecording(frame DesktopFrame, policy DesktopRecordingPolicy) error {
	switch frame.FrameType {
	case DesktopFrameTypeUpdate:
		if !policy.ScreenEnabled {
			return ErrDesktopContentRecord
		}
	case DesktopFrameTypeClipboard:
		if !policy.ClipboardEnabled {
			return ErrDesktopContentRecord
		}
	}

	return nil
}

// EncodeDesktopFramePayload validates and serializes a typed desktop frame for
// transport inside the existing ConsoleFrame data field.
func EncodeDesktopFramePayload(frame DesktopFrame, policy DesktopScreenPolicy) ([]byte, error) {
	return EncodeDesktopFramePayloadWithPolicy(frame, policy, DesktopRedirectionPolicy{})
}

// EncodeDesktopFramePayloadWithPolicy validates and serializes a typed desktop
// frame with an explicit redirection policy.
func EncodeDesktopFramePayloadWithPolicy(
	frame DesktopFrame,
	policy DesktopScreenPolicy,
	redirection DesktopRedirectionPolicy,
) ([]byte, error) {
	if err := ValidateDesktopFrameWithPolicy(frame, policy, redirection); err != nil {
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
	return DecodeDesktopFramePayloadWithPolicy(data, policy, DesktopRedirectionPolicy{})
}

// DecodeDesktopFramePayloadWithPolicy decodes and validates a typed desktop
// frame with an explicit redirection policy.
func DecodeDesktopFramePayloadWithPolicy(
	data []byte,
	policy DesktopScreenPolicy,
	redirection DesktopRedirectionPolicy,
) (DesktopFrame, error) {
	var frame DesktopFrame
	if err := json.Unmarshal(data, &frame); err != nil {
		return frame, fmt.Errorf("%w: decode frame payload: %w", ErrInvalidDesktopFrame, err)
	}
	if err := ValidateDesktopFrameWithPolicy(frame, policy, redirection); err != nil {
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
	return DecodeDesktopFramePayloadForSessionWithPolicy(data, policy, DesktopRedirectionPolicy{}, sessionID)
}

// DecodeDesktopFramePayloadForSessionWithPolicy decodes a typed desktop frame,
// applies redirection policy, and rejects frames not bound to the expected
// remote-access session.
func DecodeDesktopFramePayloadForSessionWithPolicy(
	data []byte,
	policy DesktopScreenPolicy,
	redirection DesktopRedirectionPolicy,
	sessionID string,
) (DesktopFrame, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return DesktopFrame{}, fmt.Errorf("%w: missing session binding", ErrInvalidDesktopFrame)
	}

	frame, err := DecodeDesktopFramePayloadWithPolicy(data, policy, redirection)
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
	target.Route.AllowedAgentIDs = normalizeDesktopStringList(target.Route.AllowedAgentIDs)
	target.Upstream.Host = strings.TrimSpace(target.Upstream.Host)
	target.TLS.Mode = strings.TrimSpace(target.TLS.Mode)
	target.TLS.CABundleID = strings.TrimSpace(target.TLS.CABundleID)
	target.TLS.ServerName = strings.TrimSpace(target.TLS.ServerName)
	target.Credential.Mode = strings.TrimSpace(target.Credential.Mode)
	target.Credential.AllowedPrincipals = normalizeDesktopStringList(target.Credential.AllowedPrincipals)
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
	return NormalizeDesktopCredentialGrantAt(grant, target, nowUnix())
}

// NormalizeDesktopCredentialGrantAt validates a desktop credential grant at a
// caller-provided Unix timestamp. Tests and adapters with trusted clocks can
// use this to make brokered-secret TTL decisions explicit.
func NormalizeDesktopCredentialGrantAt(
	grant DesktopCredentialGrant,
	target DesktopTarget,
	nowUnix int64,
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
		if nowUnix > 0 && grant.ExpiresUnix <= nowUnix {
			return grant, fmt.Errorf("%w: brokered credential grant expired", ErrInvalidDesktopTarget)
		}
	case DesktopCredentialModeMemoryUser:
		if grant.Username == "" || grant.Password == "" {
			return grant, fmt.Errorf("%w: memory user credential grant requires username and password", ErrInvalidDesktopTarget)
		}
		if !desktopStringListAllows(target.Credential.AllowedPrincipals, grant.Username) {
			return grant, fmt.Errorf("%w: credential grant principal not allowed by target policy", ErrInvalidDesktopTarget)
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
		if err := validateDesktopInputEvent(*frame.Input, policy); err != nil {
			return err
		}
	case DesktopFrameTypeClipboard:
		if !desktopClipboardFrameAllowed(redirection, frame.Direction) {
			return fmt.Errorf("%w: clipboard redirection disabled", ErrInvalidDesktopFrame)
		}
		if len(frame.Data) > MaxTerminalFrameData {
			return fmt.Errorf("%w: clipboard data exceeds maximum", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeQuality:
		if frame.Quality == nil {
			return fmt.Errorf("%w: missing quality request", ErrInvalidDesktopFrame)
		}
		if frame.Quality.MaxFrameRate > policy.FrameRate ||
			frame.Quality.MaxBitrate > policy.BitrateBPS ||
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

func validateDesktopInputEvent(input DesktopInputEvent, policy DesktopScreenPolicy) error {
	if len(input.Key) > DesktopMaxInputTokenSize || len(input.Button) > DesktopMaxInputTokenSize {
		return fmt.Errorf("%w: input token exceeds maximum", ErrInvalidDesktopFrame)
	}
	if input.Kind == DesktopInputKindPointer &&
		(input.X > policy.MaxWidth || input.Y > policy.MaxHeight) {
		return fmt.Errorf("%w: pointer coordinates exceed policy", ErrInvalidDesktopFrame)
	}

	return nil
}

func desktopClipboardFrameAllowed(redirection *DesktopRedirectionPolicy, direction string) bool {
	if redirection == nil {
		return false
	}

	policy := normalizeDesktopRedirectionPolicy(*redirection)

	switch strings.TrimSpace(direction) {
	case DesktopClipboardDirectionToRemote:
		return policy.ClipboardMode == DesktopClipboardModeTextToRemote ||
			policy.ClipboardMode == DesktopClipboardModeTextBoth
	case DesktopClipboardDirectionToBrowser:
		return policy.ClipboardMode == DesktopClipboardModeTextToBrowser ||
			policy.ClipboardMode == DesktopClipboardModeTextBoth
	default:
		return false
	}
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
	if !desktopStringListAllows(target.Route.AllowedAgentIDs, target.Route.SelectedAgentID) {
		return fmt.Errorf("%w: selected agent outside allowed route set", ErrInvalidDesktopTarget)
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

func normalizeDesktopStringList(values []string) []string {
	if len(values) == 0 {
		return nil
	}

	normalized := values[:0]
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			normalized = append(normalized, value)
		}
	}

	return normalized
}

func desktopStringListAllows(allowed []string, value string) bool {
	if len(allowed) == 0 {
		return true
	}

	return desktopStringListContains(allowed, value)
}

func desktopStringListContains(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}

	return false
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

func validDesktopLifecycleEventType(eventType string) bool {
	switch eventType {
	case DesktopLifecycleEventOpen,
		DesktopLifecycleEventReady,
		DesktopLifecycleEventClose,
		DesktopLifecycleEventError,
		DesktopLifecycleEventRevoked:
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
