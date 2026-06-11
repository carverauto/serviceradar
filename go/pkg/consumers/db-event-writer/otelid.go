package dbeventwriter

// Canonical OTel ID normalization (refactor-otel-signal-correlation, D1).
//
// Contract: trace_id = 32-char lowercase hex, span_id/parent_span_id =
// 16-char lowercase hex. Absent, invalid, or all-zero ids normalize to the
// empty string; the database layer stores empty ids as SQL NULL.
//
// Incoming ids arrive in several shapes depending on the producer:
//   - raw protobuf bytes (N bytes: 16 trace / 8 span)
//   - ASCII hex text inside protobuf bytes fields (the Erlang OTLP exporter
//     copies hex logger metadata verbatim into LogRecord trace_id/span_id)
//   - legacy double-hex text (hex of the ASCII hex string, via JSON)
//   - standard base64 (protobuf JSON encoding of bytes fields)

import (
	"encoding/base64"
	"encoding/hex"
	"strings"
)

const (
	traceIDByteLen = 16
	spanIDByteLen  = 8
)

// NormalizeTraceID canonicalizes a trace id from raw bytes or text into
// 32-char lowercase hex. Absent/invalid/all-zero inputs yield "".
func NormalizeTraceID[T ~string | ~[]byte](id T) string {
	return normalizeOTELID(string(id), traceIDByteLen)
}

// NormalizeSpanID canonicalizes a span id from raw bytes or text into
// 16-char lowercase hex. Absent/invalid/all-zero inputs yield "".
func NormalizeSpanID[T ~string | ~[]byte](id T) string {
	return normalizeOTELID(string(id), spanIDByteLen)
}

// NormalizeParentSpanID canonicalizes a parent span id. OTLP root spans may
// carry 8 zero bytes (or zero hex) for the parent; those normalize to "".
func NormalizeParentSpanID[T ~string | ~[]byte](id T) string {
	return normalizeOTELID(string(id), spanIDByteLen)
}

// normalizeOTELID applies the canonical id contract for an id of expected
// raw byte length byteLen. The branches are ordered: raw bytes, ASCII hex,
// legacy double-hex, base64. Anything else is rejected to "".
func normalizeOTELID(raw string, byteLen int) string {
	if raw == "" {
		return ""
	}

	hexLen := byteLen * 2
	canonical := ""

	switch {
	case len(raw) == byteLen:
		// Raw protobuf bytes.
		canonical = hex.EncodeToString([]byte(raw))
	case len(raw) == hexLen && isASCIIHex(raw):
		// Already canonical hex (possibly uppercase). Lowering instead of
		// re-encoding prevents double-encoding ASCII-hex-in-bytes payloads.
		canonical = strings.ToLower(raw)
	case len(raw) == hexLen*2 && isASCIIHex(raw):
		// Legacy double-hex: hex of the ASCII hex string. Decode once and
		// require the decoded payload to itself be ASCII hex.
		if decoded, err := hex.DecodeString(raw); err == nil {
			if inner := string(decoded); isASCIIHex(inner) {
				canonical = strings.ToLower(inner)
			}
		}
	}

	if canonical == "" {
		if decoded, err := base64.StdEncoding.DecodeString(raw); err == nil && len(decoded) == byteLen {
			canonical = hex.EncodeToString(decoded)
		}
	}

	if canonical == "" {
		otelIDRejected.Add(1)
		return ""
	}

	if isAllZeroHex(canonical) {
		return ""
	}

	return canonical
}

func isASCIIHex(s string) bool {
	if s == "" {
		return false
	}

	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F') {
			return false
		}
	}

	return true
}

func isAllZeroHex(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] != '0' {
			return false
		}
	}

	return true
}
