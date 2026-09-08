package cli

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

func TestShowHelpDoesNotAdvertiseTLSSkipVerify(t *testing.T) {
	output := captureStdout(t, ShowHelp)

	if strings.Contains(output, "tls-skip-verify") {
		t.Fatalf("expected help output to remove tls-skip-verify flag, got %q", output)
	}
}

func TestNewHTTPClientUsesDefaultVerifiedTransport(t *testing.T) {
	client := newHTTPClient()

	if client.Transport != nil {
		t.Fatalf("expected default verified transport, got custom transport %#v", client.Transport)
	}
	if client.Timeout != 15*time.Second {
		t.Fatalf("expected 15s timeout, got %s", client.Timeout)
	}
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()

	originalStdout := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("create pipe: %v", err)
	}

	os.Stdout = writer
	defer func() {
		os.Stdout = originalStdout
	}()

	fn()

	if err := writer.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}

	var buf bytes.Buffer
	if _, err := io.Copy(&buf, reader); err != nil {
		t.Fatalf("read stdout: %v", err)
	}

	if err := reader.Close(); err != nil {
		t.Fatalf("close reader: %v", err)
	}

	return buf.String()
}
