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
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"regexp"
	"strings"
	"syscall"

	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/liberrors"
)

// Camera relay source failure classes. Core stores "<class>: <detail>" as the
// relay session's failure_reason and turns the class into operator text, so
// these strings are a wire contract: add classes, do not rename them.
const (
	cameraRelayFailureInvalidSourceConfig = "invalid_source_config"
	cameraRelayFailurePluginUnavailable   = "plugin_unavailable"
	cameraRelayFailureDNS                 = "dns_failure"
	cameraRelayFailureConnectRefused      = "connect_refused"
	cameraRelayFailureConnectTimeout      = "connect_timeout"
	cameraRelayFailureHostUnreachable     = "host_unreachable"
	cameraRelayFailureConnectFailed       = "connect_failed"
	cameraRelayFailureTLSCertificate      = "tls_certificate_invalid"
	cameraRelayFailureTLSHandshake        = "tls_handshake_failed"
	cameraRelayFailureAuthentication      = "authentication_failed"
	cameraRelayFailureNotFound            = "not_found"
	cameraRelayFailureRTSPRequest         = "rtsp_request_failed"
	cameraRelayFailureResponseTimeout     = "response_timeout"
	cameraRelayFailureNoVideoTrack        = "no_video_track"
	cameraRelayFailureUnsupportedCodec    = "unsupported_codec"
	cameraRelayFailureMediaDecode         = "media_decode_failed"
	cameraRelayFailureNoKeyframe          = "no_keyframe"
	cameraRelayFailureNoMedia             = "read_timeout_no_media"
	cameraRelayFailureUpstreamClosed      = "upstream_closed"
	cameraRelayFailureStartDeadline       = "start_deadline_exceeded"
	cameraRelayFailureUnknown             = "unknown"
)

const (
	maxCameraRelayFailureDetail = 200
	// Bounds regex work on a pathological error string before sanitizing.
	maxCameraRelayFailureInput = 4096
)

var (
	errCameraRelayInvalidSourceURL  = errors.New("source_url is not a valid rtsp url")
	errCameraRelayNoVideoTrack      = errors.New("rtsp stream has no video track")
	errCameraRelayUnsupportedCodec  = errors.New("rtsp stream video codec is not supported, H264 is required")
	errCameraRelayMediaDecodeFailed = errors.New("camera relay media decode failed")
)

// Each pattern removes material that can carry a credential: a URL (userinfo,
// path alias tokens, query tokens), bare userinfo, a query string, or a path.
var (
	cameraRelayFailureURLPattern      = regexp.MustCompile(`(?i)[a-z][a-z0-9+.\-]*://[^\s"'<>]*`)
	cameraRelayFailureUserinfoPattern = regexp.MustCompile(`[^\s"'<>@/]+@`)
	cameraRelayFailureQueryPattern    = regexp.MustCompile(`\?[^\s"'<>]*`)
	cameraRelayFailureHostPathPattern = regexp.MustCompile(`([A-Za-z0-9\-\]]+(?:\.[A-Za-z0-9\-]+)*(?::\d+)?)/[^\s"'<>)]*`)
	cameraRelayFailurePathPattern     = regexp.MustCompile(`(^|[\s"'(=:])/[^\s"'<>)]*`)
	cameraRelayFailureSpacePattern    = regexp.MustCompile(`\s+`)
)

// cameraRelayFailure is the bounded, credential-free account of why a camera
// source could not start or stopped delivering media.
type cameraRelayFailure struct {
	Class  string
	Detail string
}

func (f cameraRelayFailure) String() string {
	if f.Class == "" {
		return ""
	}
	if f.Detail == "" {
		return f.Class
	}
	return f.Class + ": " + f.Detail
}

// cameraRelaySourceStartError is returned to the command sender in place of the
// raw source error, whose text may contain the stream URL.
type cameraRelaySourceStartError struct {
	failure cameraRelayFailure
	err     error
}

func (e *cameraRelaySourceStartError) Error() string {
	if e.failure.Class == "" {
		return "camera source start cancelled"
	}
	return "camera source failed to start: " + e.failure.String()
}

func (e *cameraRelaySourceStartError) Unwrap() error {
	return e.err
}

func classifyCameraRelayFailure(err error) cameraRelayFailure {
	if err == nil {
		return cameraRelayFailure{}
	}

	return cameraRelayFailure{
		Class:  cameraRelayFailureClass(err),
		Detail: sanitizeCameraRelayFailureDetail(err.Error()),
	}
}

func cameraRelayFailureClass(err error) string {
	for _, classify := range []func(error) string{
		cameraRelaySourceFailureClass,
		cameraRelayTLSFailureClass,
		cameraRelayNetworkFailureClass,
		cameraRelayRTSPFailureClass,
	} {
		if class := classify(err); class != "" {
			return class
		}
	}

	if errors.Is(err, context.DeadlineExceeded) {
		return cameraRelayFailureStartDeadline
	}

	return cameraRelayFailureUnknown
}

func cameraRelaySourceFailureClass(err error) string {
	switch {
	case errors.Is(err, errCameraRelaySourceURLRequired),
		errors.Is(err, errCameraRelayInvalidSourceURL),
		errors.Is(err, errUnsupportedCameraRelaySource),
		errors.Is(err, errUnsupportedCameraRelayTransport),
		errors.As(err, new(liberrors.ErrClientUnsupportedScheme)):
		return cameraRelayFailureInvalidSourceConfig
	case errors.Is(err, errCameraRelayPluginUnavailable),
		errors.Is(err, errStreamingPluginAssignmentNotFound),
		errors.Is(err, errStreamingPluginAdmissionDenied):
		return cameraRelayFailurePluginUnavailable
	case errors.Is(err, errCameraRelayNoVideoTrack):
		return cameraRelayFailureNoVideoTrack
	case errors.Is(err, errCameraRelayUnsupportedCodec),
		errors.As(err, new(liberrors.ErrClientH264PacketizationMode0)):
		return cameraRelayFailureUnsupportedCodec
	case errors.Is(err, errCameraRelayMediaDecodeFailed):
		return cameraRelayFailureMediaDecode
	case errors.Is(err, errCameraRelayNoKeyframe):
		return cameraRelayFailureNoKeyframe
	default:
		return ""
	}
}

func cameraRelayTLSFailureClass(err error) string {
	var certErr *tls.CertificateVerificationError
	var recordErr tls.RecordHeaderError
	var opErr *net.OpError

	switch {
	case errors.As(err, &certErr),
		errors.As(err, new(x509.UnknownAuthorityError)),
		errors.As(err, new(x509.HostnameError)),
		errors.As(err, new(x509.CertificateInvalidError)):
		return cameraRelayFailureTLSCertificate
	case errors.As(err, &recordErr):
		return cameraRelayFailureTLSHandshake
	case errors.As(err, &opErr) && opErr.Op == "remote error":
		// crypto/tls reports a TLS alert from the peer this way.
		return cameraRelayFailureTLSHandshake
	case strings.Contains(err.Error(), "tls: "):
		return cameraRelayFailureTLSHandshake
	default:
		return ""
	}
}

func cameraRelayNetworkFailureClass(err error) string {
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return cameraRelayFailureDNS
	}

	var opErr *net.OpError
	if errors.As(err, &opErr) && opErr.Op == "dial" {
		switch {
		case errors.Is(err, syscall.ECONNREFUSED):
			return cameraRelayFailureConnectRefused
		case opErr.Timeout(), errors.Is(err, context.DeadlineExceeded):
			return cameraRelayFailureConnectTimeout
		case errors.Is(err, syscall.EHOSTUNREACH), errors.Is(err, syscall.ENETUNREACH):
			return cameraRelayFailureHostUnreachable
		default:
			return cameraRelayFailureConnectFailed
		}
	}

	switch {
	case errors.Is(err, io.EOF),
		errors.Is(err, io.ErrUnexpectedEOF),
		errors.Is(err, syscall.ECONNRESET),
		errors.Is(err, syscall.EPIPE):
		return cameraRelayFailureUpstreamClosed
	default:
		return ""
	}
}

func cameraRelayRTSPFailureClass(err error) string {
	var statusErr liberrors.ErrClientBadStatusCode

	switch {
	case errors.As(err, &statusErr):
		return cameraRelayRTSPStatusClass(statusErr.Code)
	case errors.As(err, new(liberrors.ErrClientAuthSetup)):
		return cameraRelayFailureAuthentication
	case errors.As(err, new(liberrors.ErrClientRequestTimedOut)):
		return cameraRelayFailureResponseTimeout
	case errors.As(err, new(liberrors.ErrClientTCPTimeout)),
		errors.As(err, new(liberrors.ErrClientUDPTimeout)):
		return cameraRelayFailureNoMedia
	default:
		return ""
	}
}

func cameraRelayRTSPStatusClass(code base.StatusCode) string {
	if code == base.StatusUnauthorized || code == base.StatusForbidden {
		return cameraRelayFailureAuthentication
	}
	if code == base.StatusNotFound {
		return cameraRelayFailureNotFound
	}
	// Any other status names the code in the detail text.
	return cameraRelayFailureRTSPRequest
}

// sanitizeCameraRelayFailureDetail reduces an error string to at most
// maxCameraRelayFailureDetail printable ASCII characters with every URL,
// userinfo, query string and path removed. RTSP URLs carry usernames,
// passwords and alias tokens, so none of them may leave the agent.
func sanitizeCameraRelayFailureDetail(raw string) string {
	if len(raw) > maxCameraRelayFailureInput {
		raw = raw[:maxCameraRelayFailureInput]
	}

	detail := strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e {
			return ' '
		}
		return r
	}, raw)

	detail = cameraRelayFailureURLPattern.ReplaceAllString(detail, "[url]")
	detail = cameraRelayFailureUserinfoPattern.ReplaceAllString(detail, "")
	detail = cameraRelayFailureQueryPattern.ReplaceAllString(detail, "")
	detail = cameraRelayFailureHostPathPattern.ReplaceAllString(detail, "$1")
	detail = cameraRelayFailurePathPattern.ReplaceAllString(detail, "$1[path]")
	detail = strings.TrimSpace(cameraRelayFailureSpacePattern.ReplaceAllString(detail, " "))

	if len(detail) > maxCameraRelayFailureDetail {
		detail = strings.TrimSpace(detail[:maxCameraRelayFailureDetail])
	}

	return detail
}
