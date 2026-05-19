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
	"fmt"
	"net/url"
	"strings"
)

const (
	FrameTypeApplicationOpen             = "app_open"
	FrameTypeApplicationRequest          = "app_request"
	FrameTypeApplicationResponseMetadata = "app_response_metadata"
	FrameTypeApplicationData             = "app_data"
	FrameTypeApplicationProgress         = "app_progress"
	FrameTypeApplicationClose            = "app_close"
	FrameTypeApplicationError            = "app_error"
	FrameTypeApplicationOutcome          = "app_outcome"

	FrameTypeTCPOpen     = "tcp_open"
	FrameTypeTCPData     = "tcp_data"
	FrameTypeTCPProgress = "tcp_progress"
	FrameTypeTCPClose    = "tcp_close"
	FrameTypeTCPError    = "tcp_error"
	FrameTypeTCPOutcome  = "tcp_outcome"

	ApplicationSchemeHTTP  ApplicationScheme = "http"
	ApplicationSchemeHTTPS ApplicationScheme = "https"

	ApplicationDataDirectionRequest  ApplicationDataDirection = "request"
	ApplicationDataDirectionResponse ApplicationDataDirection = "response"
	TCPDataDirectionClient           TCPDataDirection         = "client"
	TCPDataDirectionUpstream         TCPDataDirection         = "upstream"

	ApplicationStatusStarted        RemoteAccessStreamStatus = "started"
	ApplicationStatusInProgress     RemoteAccessStreamStatus = "in_progress"
	ApplicationStatusCompleted      RemoteAccessStreamStatus = "completed"
	ApplicationStatusDenied         RemoteAccessStreamStatus = "denied"
	ApplicationStatusFailed         RemoteAccessStreamStatus = "failed"
	ApplicationStatusQuotaExhausted RemoteAccessStreamStatus = "quota_exhausted"
	ApplicationStatusClosed         RemoteAccessStreamStatus = "closed"

	TCPStatusStarted        RemoteAccessStreamStatus = ApplicationStatusStarted
	TCPStatusInProgress     RemoteAccessStreamStatus = ApplicationStatusInProgress
	TCPStatusCompleted      RemoteAccessStreamStatus = ApplicationStatusCompleted
	TCPStatusDenied         RemoteAccessStreamStatus = ApplicationStatusDenied
	TCPStatusFailed         RemoteAccessStreamStatus = ApplicationStatusFailed
	TCPStatusQuotaExhausted RemoteAccessStreamStatus = ApplicationStatusQuotaExhausted
	TCPStatusClosed         RemoteAccessStreamStatus = ApplicationStatusClosed
)

var (
	ErrInvalidApplicationTargetID      = errors.New("invalid application target id")
	ErrInvalidApplicationSessionID     = errors.New("invalid application session id")
	ErrInvalidApplicationScheme        = errors.New("invalid application scheme")
	ErrInvalidApplicationUpstreamHost  = errors.New("invalid application upstream host")
	ErrInvalidApplicationUpstreamPort  = errors.New("invalid application upstream port")
	ErrInvalidApplicationRequestID     = errors.New("invalid application request id")
	ErrInvalidApplicationMethod        = errors.New("invalid application method")
	ErrInvalidApplicationPath          = errors.New("invalid application path")
	ErrInvalidApplicationDataDirection = errors.New("invalid application data direction")
	ErrInvalidApplicationSequence      = errors.New("invalid application sequence")
	ErrInvalidApplicationStatus        = errors.New("invalid application status")

	ErrInvalidTCPTargetID      = errors.New("invalid tcp target id")
	ErrInvalidTCPSessionID     = errors.New("invalid tcp session id")
	ErrInvalidTCPConnectionID  = errors.New("invalid tcp connection id")
	ErrInvalidTCPUpstreamHost  = errors.New("invalid tcp upstream host")
	ErrInvalidTCPUpstreamPort  = errors.New("invalid tcp upstream port")
	ErrInvalidTCPDataDirection = errors.New("invalid tcp data direction")
	ErrInvalidTCPSequence      = errors.New("invalid tcp sequence")
	ErrInvalidTCPStatus        = errors.New("invalid tcp status")
)

// ApplicationScheme identifies the trusted upstream scheme selected from target policy.
type ApplicationScheme string

// ApplicationDataDirection marks whether bounded bytes flow toward the
// application upstream or back toward the browser.
type ApplicationDataDirection string

// TCPDataDirection marks whether bounded bytes flow toward the TCP upstream or
// back toward the client renderer.
type TCPDataDirection string

// RemoteAccessStreamStatus is the status vocabulary shared by app/TCP progress,
// error, and outcome frames.
type RemoteAccessStreamStatus string

// ApplicationOpenPayload is carried by FrameTypeApplicationOpen after the
// control plane has resolved a registered target. It is never accepted directly
// from browser intent.
type ApplicationOpenPayload struct {
	TargetID                string            `json:"target_id"`
	SessionID               string            `json:"session_id"`
	Scheme                  ApplicationScheme `json:"scheme"`
	UpstreamHost            string            `json:"upstream_host"`
	UpstreamPort            int               `json:"upstream_port"`
	HostHeader              string            `json:"host_header,omitempty"`
	SNI                     string            `json:"sni,omitempty"`
	TLSPolicy               map[string]any    `json:"tls_policy,omitempty"`
	CABundleRef             string            `json:"ca_bundle_ref,omitempty"`
	AllowedMethods          []string          `json:"allowed_methods,omitempty"`
	AllowedPathPrefixes     []string          `json:"allowed_path_prefixes,omitempty"`
	HeaderPolicy            map[string]any    `json:"header_policy,omitempty"`
	CookiePolicy            map[string]any    `json:"cookie_policy,omitempty"`
	QuotaPolicy             map[string]any    `json:"quota_policy,omitempty"`
	ApprovalID              string            `json:"approval_id,omitempty"`
	RecordingPolicy         map[string]any    `json:"recording_policy,omitempty"`
	EnhancedRecordingPolicy map[string]any    `json:"enhanced_recording_policy,omitempty"`
	Metadata                map[string]string `json:"metadata,omitempty"`
}

// ApplicationRequestPayload carries request metadata only. Request bodies use
// FrameTypeApplicationData and must stay bounded by adapter quota policy.
type ApplicationRequestPayload struct {
	RequestID string              `json:"request_id"`
	SessionID string              `json:"session_id"`
	Method    string              `json:"method"`
	Path      string              `json:"path"`
	Query     string              `json:"query,omitempty"`
	Headers   map[string][]string `json:"headers,omitempty"`
}

// ApplicationResponseMetadataPayload carries response headers and status without body bytes.
type ApplicationResponseMetadataPayload struct {
	RequestID   string              `json:"request_id"`
	SessionID   string              `json:"session_id"`
	StatusCode  int                 `json:"status_code"`
	Headers     map[string][]string `json:"headers,omitempty"`
	ContentType string              `json:"content_type,omitempty"`
}

// ApplicationDataPayload carries one bounded request or response body chunk.
type ApplicationDataPayload struct {
	RequestID string                   `json:"request_id"`
	SessionID string                   `json:"session_id"`
	Direction ApplicationDataDirection `json:"direction"`
	Sequence  uint64                   `json:"sequence"`
	Data      []byte                   `json:"data,omitempty"`
	EOF       bool                     `json:"eof,omitempty"`
}

// ApplicationProgressPayload reports lifecycle and byte-count metadata.
type ApplicationProgressPayload struct {
	RequestID     string                   `json:"request_id,omitempty"`
	SessionID     string                   `json:"session_id"`
	Status        RemoteAccessStreamStatus `json:"status"`
	RequestBytes  int64                    `json:"request_bytes,omitempty"`
	ResponseBytes int64                    `json:"response_bytes,omitempty"`
}

// ApplicationClosePayload reports an orderly application request or session close.
type ApplicationClosePayload struct {
	RequestID string `json:"request_id,omitempty"`
	SessionID string `json:"session_id"`
	Reason    string `json:"reason,omitempty"`
}

// ApplicationErrorPayload reports a denied, failed, or quota-exhausted application action.
type ApplicationErrorPayload struct {
	RequestID string                   `json:"request_id,omitempty"`
	SessionID string                   `json:"session_id"`
	Status    RemoteAccessStreamStatus `json:"status"`
	Code      string                   `json:"code"`
	Message   string                   `json:"message,omitempty"`
}

// ApplicationOutcomePayload reports durable metadata for audit and replay.
type ApplicationOutcomePayload struct {
	SessionID     string                   `json:"session_id"`
	TargetID      string                   `json:"target_id"`
	Status        RemoteAccessStreamStatus `json:"status"`
	RequestCount  int64                    `json:"request_count,omitempty"`
	RequestBytes  int64                    `json:"request_bytes,omitempty"`
	ResponseBytes int64                    `json:"response_bytes,omitempty"`
	FailureReason string                   `json:"failure_reason,omitempty"`
}

// TCPOpenPayload is carried by FrameTypeTCPOpen after target policy resolution.
type TCPOpenPayload struct {
	TargetID                string            `json:"target_id"`
	SessionID               string            `json:"session_id"`
	ConnectionID            string            `json:"connection_id"`
	UpstreamHost            string            `json:"upstream_host"`
	UpstreamPort            int               `json:"upstream_port"`
	ProtocolName            string            `json:"protocol_name,omitempty"`
	IdleTimeoutSeconds      int               `json:"idle_timeout_seconds,omitempty"`
	AbsoluteTimeoutSeconds  int               `json:"absolute_timeout_seconds,omitempty"`
	QuotaPolicy             map[string]any    `json:"quota_policy,omitempty"`
	ApprovalID              string            `json:"approval_id,omitempty"`
	RecordingPolicy         map[string]any    `json:"recording_policy,omitempty"`
	EnhancedRecordingPolicy map[string]any    `json:"enhanced_recording_policy,omitempty"`
	Metadata                map[string]string `json:"metadata,omitempty"`
}

// TCPDataPayload carries one bounded byte chunk for an explicitly registered TCP target.
type TCPDataPayload struct {
	SessionID    string           `json:"session_id"`
	ConnectionID string           `json:"connection_id"`
	Direction    TCPDataDirection `json:"direction"`
	Sequence     uint64           `json:"sequence"`
	Data         []byte           `json:"data,omitempty"`
	EOF          bool             `json:"eof,omitempty"`
}

// TCPProgressPayload reports TCP connection lifecycle and byte-count metadata.
type TCPProgressPayload struct {
	SessionID    string                   `json:"session_id"`
	ConnectionID string                   `json:"connection_id"`
	Status       RemoteAccessStreamStatus `json:"status"`
	BytesIn      int64                    `json:"bytes_in,omitempty"`
	BytesOut     int64                    `json:"bytes_out,omitempty"`
}

// TCPClosePayload reports an orderly TCP connection close.
type TCPClosePayload struct {
	SessionID    string `json:"session_id"`
	ConnectionID string `json:"connection_id"`
	Reason       string `json:"reason,omitempty"`
}

// TCPErrorPayload reports a denied, failed, or quota-exhausted TCP stream.
type TCPErrorPayload struct {
	SessionID    string                   `json:"session_id"`
	ConnectionID string                   `json:"connection_id,omitempty"`
	Status       RemoteAccessStreamStatus `json:"status"`
	Code         string                   `json:"code"`
	Message      string                   `json:"message,omitempty"`
}

// TCPOutcomePayload reports durable TCP metadata for audit and replay.
type TCPOutcomePayload struct {
	SessionID     string                   `json:"session_id"`
	TargetID      string                   `json:"target_id"`
	ConnectionID  string                   `json:"connection_id"`
	Status        RemoteAccessStreamStatus `json:"status"`
	BytesIn       int64                    `json:"bytes_in,omitempty"`
	BytesOut      int64                    `json:"bytes_out,omitempty"`
	FailureReason string                   `json:"failure_reason,omitempty"`
}

func (p ApplicationOpenPayload) Validate() error {
	if strings.TrimSpace(p.TargetID) == "" {
		return ErrInvalidApplicationTargetID
	}
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidApplicationSessionID
	}
	if !p.Scheme.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidApplicationScheme, p.Scheme)
	}
	if strings.TrimSpace(p.UpstreamHost) == "" {
		return ErrInvalidApplicationUpstreamHost
	}
	if !validPort(p.UpstreamPort) {
		return ErrInvalidApplicationUpstreamPort
	}
	for _, method := range p.AllowedMethods {
		if strings.TrimSpace(method) == "" {
			return ErrInvalidApplicationMethod
		}
	}
	for _, prefix := range p.AllowedPathPrefixes {
		if !validApplicationPath(prefix) {
			return ErrInvalidApplicationPath
		}
	}

	return nil
}

func (p ApplicationRequestPayload) Validate() error {
	if strings.TrimSpace(p.RequestID) == "" {
		return ErrInvalidApplicationRequestID
	}
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidApplicationSessionID
	}
	if strings.TrimSpace(p.Method) == "" {
		return ErrInvalidApplicationMethod
	}
	if !validApplicationPath(p.Path) {
		return ErrInvalidApplicationPath
	}

	return nil
}

func (p ApplicationResponseMetadataPayload) Validate() error {
	if strings.TrimSpace(p.RequestID) == "" {
		return ErrInvalidApplicationRequestID
	}
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidApplicationSessionID
	}
	if p.StatusCode < 100 || p.StatusCode > 599 {
		return ErrInvalidApplicationStatus
	}

	return nil
}

func (p ApplicationDataPayload) Validate() error {
	if strings.TrimSpace(p.RequestID) == "" {
		return ErrInvalidApplicationRequestID
	}
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidApplicationSessionID
	}
	if !p.Direction.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidApplicationDataDirection, p.Direction)
	}
	if p.Sequence == 0 {
		return ErrInvalidApplicationSequence
	}
	if len(p.Data) > MaxTerminalFrameData {
		return ErrInvalidFrameSize
	}

	return nil
}

func (p ApplicationProgressPayload) Validate() error {
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidApplicationSessionID
	}
	if !p.Status.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidApplicationStatus, p.Status)
	}

	return nil
}

func (p ApplicationClosePayload) Validate() error {
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidApplicationSessionID
	}

	return nil
}

func (p ApplicationErrorPayload) Validate() error {
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidApplicationSessionID
	}
	if !p.Status.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidApplicationStatus, p.Status)
	}
	if strings.TrimSpace(p.Code) == "" {
		return ErrInvalidApplicationStatus
	}

	return nil
}

func (p ApplicationOutcomePayload) Validate() error {
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidApplicationSessionID
	}
	if strings.TrimSpace(p.TargetID) == "" {
		return ErrInvalidApplicationTargetID
	}
	if !p.Status.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidApplicationStatus, p.Status)
	}

	return nil
}

func (p TCPOpenPayload) Validate() error {
	if strings.TrimSpace(p.TargetID) == "" {
		return ErrInvalidTCPTargetID
	}
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidTCPSessionID
	}
	if strings.TrimSpace(p.ConnectionID) == "" {
		return ErrInvalidTCPConnectionID
	}
	if strings.TrimSpace(p.UpstreamHost) == "" {
		return ErrInvalidTCPUpstreamHost
	}
	if !validPort(p.UpstreamPort) {
		return ErrInvalidTCPUpstreamPort
	}

	return nil
}

func (p TCPDataPayload) Validate() error {
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidTCPSessionID
	}
	if strings.TrimSpace(p.ConnectionID) == "" {
		return ErrInvalidTCPConnectionID
	}
	if !p.Direction.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidTCPDataDirection, p.Direction)
	}
	if p.Sequence == 0 {
		return ErrInvalidTCPSequence
	}

	return nil
}

func (p TCPProgressPayload) Validate() error {
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidTCPSessionID
	}
	if strings.TrimSpace(p.ConnectionID) == "" {
		return ErrInvalidTCPConnectionID
	}
	if !p.Status.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidTCPStatus, p.Status)
	}

	return nil
}

func (p TCPClosePayload) Validate() error {
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidTCPSessionID
	}
	if strings.TrimSpace(p.ConnectionID) == "" {
		return ErrInvalidTCPConnectionID
	}

	return nil
}

func (p TCPErrorPayload) Validate() error {
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidTCPSessionID
	}
	if !p.Status.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidTCPStatus, p.Status)
	}
	if strings.TrimSpace(p.Code) == "" {
		return ErrInvalidTCPStatus
	}

	return nil
}

func (p TCPOutcomePayload) Validate() error {
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidTCPSessionID
	}
	if strings.TrimSpace(p.TargetID) == "" {
		return ErrInvalidTCPTargetID
	}
	if strings.TrimSpace(p.ConnectionID) == "" {
		return ErrInvalidTCPConnectionID
	}
	if !p.Status.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidTCPStatus, p.Status)
	}

	return nil
}

// Valid returns true when the application upstream scheme is supported.
func (s ApplicationScheme) Valid() bool {
	switch s {
	case ApplicationSchemeHTTP, ApplicationSchemeHTTPS:
		return true
	default:
		return false
	}
}

// Valid returns true when the application data direction is part of the frame contract.
func (d ApplicationDataDirection) Valid() bool {
	switch d {
	case ApplicationDataDirectionRequest, ApplicationDataDirectionResponse:
		return true
	default:
		return false
	}
}

// Valid returns true when the TCP data direction is part of the frame contract.
func (d TCPDataDirection) Valid() bool {
	switch d {
	case TCPDataDirectionClient, TCPDataDirectionUpstream:
		return true
	default:
		return false
	}
}

// Valid returns true when the stream status is part of the app/TCP audit vocabulary.
func (s RemoteAccessStreamStatus) Valid() bool {
	switch s {
	case ApplicationStatusStarted, ApplicationStatusInProgress, ApplicationStatusCompleted,
		ApplicationStatusDenied, ApplicationStatusFailed, ApplicationStatusQuotaExhausted,
		ApplicationStatusClosed:
		return true
	default:
		return false
	}
}

func validPort(port int) bool {
	return port > 0 && port <= 65_535
}

func validApplicationPath(path string) bool {
	trimmed := strings.TrimSpace(path)
	if path != trimmed || !safeApplicationPath(path) {
		return false
	}

	decoded, err := url.PathUnescape(path)
	if err != nil {
		return false
	}

	return safeApplicationPath(decoded)
}

func safeApplicationPath(path string) bool {
	if !strings.HasPrefix(path, "/") || strings.HasPrefix(path, "//") ||
		strings.Contains(path, "://") || strings.Contains(path, "\\") {
		return false
	}

	for _, char := range path {
		if char < 0x20 || char == 0x7f {
			return false
		}
	}

	for _, segment := range strings.Split(path, "/") {
		if segment == "." || segment == ".." {
			return false
		}
	}

	return true
}
