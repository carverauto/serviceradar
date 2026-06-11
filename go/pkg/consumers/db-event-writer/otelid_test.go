package dbeventwriter

import (
	"encoding/base64"
	"encoding/hex"
	"testing"
)

const (
	canonicalTraceID = "0af7651916cd43dd8448eb211c80319c"
	canonicalSpanID  = "00f067aa0ba902b7"
)

func mustHexDecode(t *testing.T, s string) []byte {
	t.Helper()

	decoded, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("hex.DecodeString(%q): %v", s, err)
	}

	return decoded
}

func TestNormalizeTraceID(t *testing.T) {
	rawBytes := mustHexDecode(t, canonicalTraceID)
	doubleHex := hex.EncodeToString([]byte(canonicalTraceID))
	upperInner := "ABCDEF0123456789ABCDEF0123456789"
	doubleHexUpperInner := hex.EncodeToString([]byte(upperInner))

	cases := []struct {
		name  string
		input string
		want  string
	}{
		{"empty", "", ""},
		{"raw 16 bytes", string(rawBytes), canonicalTraceID},
		{"ascii hex lowercase", canonicalTraceID, canonicalTraceID},
		{"ascii hex uppercase", "0AF7651916CD43DD8448EB211C80319C", canonicalTraceID},
		// The Erlang OTLP exporter ships ASCII hex text inside the protobuf
		// bytes field; it must be lowered, never hex-encoded a second time.
		{"ascii hex in bytes field", string([]byte(canonicalTraceID)), canonicalTraceID},
		{"legacy double hex", doubleHex, canonicalTraceID},
		{"legacy double hex of uppercase inner", doubleHexUpperInner, "abcdef0123456789abcdef0123456789"},
		{"base64 std", base64.StdEncoding.EncodeToString(rawBytes), canonicalTraceID},
		{"base64 wrong decoded length", base64.StdEncoding.EncodeToString(rawBytes[:8]), ""},
		{"all zero raw bytes", string(make([]byte, 16)), ""},
		{"all zero hex", "00000000000000000000000000000000", ""},
		{"all zero double hex", hex.EncodeToString([]byte("00000000000000000000000000000000")), ""},
		{"garbage", "not-a-trace-id", ""},
		{"wrong length hex", canonicalTraceID[:30], ""},
		{"64-char hex but not double-encoded ascii hex", hex.EncodeToString(append(rawBytes, mustHexDecode(t, canonicalTraceID)...)), ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := NormalizeTraceID(tc.input); got != tc.want {
				t.Fatalf("NormalizeTraceID(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

func TestNormalizeTraceIDByteSlice(t *testing.T) {
	rawBytes := mustHexDecode(t, canonicalTraceID)

	if got := NormalizeTraceID(rawBytes); got != canonicalTraceID {
		t.Fatalf("NormalizeTraceID(raw bytes) = %q, want %q", got, canonicalTraceID)
	}

	if got := NormalizeTraceID([]byte(canonicalTraceID)); got != canonicalTraceID {
		t.Fatalf("NormalizeTraceID(ascii hex bytes) = %q, want %q", got, canonicalTraceID)
	}

	if got := NormalizeTraceID([]byte(nil)); got != "" {
		t.Fatalf("NormalizeTraceID(nil bytes) = %q, want empty", got)
	}
}

func TestNormalizeSpanID(t *testing.T) {
	rawBytes := mustHexDecode(t, canonicalSpanID)
	doubleHex := hex.EncodeToString([]byte(canonicalSpanID))

	cases := []struct {
		name  string
		input string
		want  string
	}{
		{"empty", "", ""},
		{"raw 8 bytes", string(rawBytes), canonicalSpanID},
		{"ascii hex lowercase", canonicalSpanID, canonicalSpanID},
		{"ascii hex uppercase", "00F067AA0BA902B7", canonicalSpanID},
		{"ascii hex in bytes field", string([]byte(canonicalSpanID)), canonicalSpanID},
		{"legacy double hex", doubleHex, canonicalSpanID},
		{"base64 std", base64.StdEncoding.EncodeToString(rawBytes), canonicalSpanID},
		{"base64 wrong decoded length", base64.StdEncoding.EncodeToString(append(append([]byte{}, rawBytes...), rawBytes[:4]...)), ""},
		{"all zero raw bytes", string(make([]byte, 8)), ""},
		{"all zero hex", "0000000000000000", ""},
		{"garbage", "zz!!zzz", ""},
		{"wrong length hex", canonicalSpanID[:14], ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := NormalizeSpanID(tc.input); got != tc.want {
				t.Fatalf("NormalizeSpanID(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

func TestNormalizeParentSpanID(t *testing.T) {
	rawBytes := mustHexDecode(t, canonicalSpanID)

	// OTLP root spans may carry an absent parent, 8 zero bytes, or zero hex —
	// all must normalize to "" (stored as SQL NULL).
	if got := NormalizeParentSpanID(""); got != "" {
		t.Fatalf("NormalizeParentSpanID(empty) = %q, want empty", got)
	}

	if got := NormalizeParentSpanID(make([]byte, 8)); got != "" {
		t.Fatalf("NormalizeParentSpanID(zero bytes) = %q, want empty", got)
	}

	if got := NormalizeParentSpanID("0000000000000000"); got != "" {
		t.Fatalf("NormalizeParentSpanID(zero hex) = %q, want empty", got)
	}

	if got := NormalizeParentSpanID(rawBytes); got != canonicalSpanID {
		t.Fatalf("NormalizeParentSpanID(raw bytes) = %q, want %q", got, canonicalSpanID)
	}
}

func TestNormalizeOTELIDRejectionCounter(t *testing.T) {
	before := otelIDRejected.Load()

	if got := NormalizeTraceID("garbage-id-val"); got != "" {
		t.Fatalf("NormalizeTraceID(garbage) = %q, want empty", got)
	}

	if after := otelIDRejected.Load(); after != before+1 {
		t.Fatalf("otelIDRejected = %d, want %d", after, before+1)
	}

	// All-zero ids are "absent", not rejections.
	beforeZero := otelIDRejected.Load()

	if got := NormalizeSpanID("0000000000000000"); got != "" {
		t.Fatalf("NormalizeSpanID(zero hex) = %q, want empty", got)
	}

	if after := otelIDRejected.Load(); after != beforeZero {
		t.Fatalf("otelIDRejected changed on all-zero id: %d -> %d", beforeZero, after)
	}
}
