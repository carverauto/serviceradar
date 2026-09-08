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
	"errors"
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
	DesktopNLAModeRequired   = "required"
	DesktopNLAModeDisabled   = "disabled"
	DesktopDefaultNLAPolicy  = DesktopNLAModeRequired
	DesktopDefaultRDPPort    = 3389
	DesktopDefaultMaxWidth   = 1920
	DesktopDefaultMaxHeight  = 1080
	DesktopDefaultFrameRate  = 30
	DesktopDefaultBitrateBPS = 8_000_000
	DesktopDefaultIdleSec    = 900
	DesktopDefaultTTLSec     = 3600
	DesktopMaxCABundlePEM    = 256 * 1024
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

// DesktopOpenPayload is the agent-side open-frame contract for graphical
// desktop protocols. It contains trusted target policy compiled by core, not
// browser-selected upstream settings.
type DesktopOpenPayload struct {
	Schema          string                  `json:"schema,omitempty"`
	ActorID         string                  `json:"actor_id,omitempty"`
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
	Mode        string `json:"mode"`
	CABundleID  string `json:"ca_bundle_id,omitempty"`
	CABundlePEM string `json:"ca_bundle_pem,omitempty"`
	NLAMode     string `json:"nla_mode,omitempty"`
	ServerName  string `json:"server_name,omitempty"`
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

func validDesktopProtocol(protocol string) bool {
	return protocol == ProtocolRDP || protocol == ProtocolDesktop
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
