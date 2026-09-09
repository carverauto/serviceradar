package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDeclaredAgentRuntimeArchiveMatchesSigningContract(t *testing.T) {
	if os.Getenv("TEST_SRCDIR") == "" {
		t.Skip("requires the runtime archive declared by the Bazel target")
	}
	resolver, err := newRunfileResolver()
	if err != nil {
		t.Fatal(err)
	}
	archive, err := resolver.resolve(defaultAgentRuntimeRunfile)
	if err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(t.TempDir(), "serviceradar-agent")
	if err := extractAgentTestRuntime(archive, binary); err != nil {
		t.Fatalf("declared runtime archive violates signing contract: %v", err)
	}
	want := os.Getenv("EXPECTED_AGENT_TEST_VERSION")
	if want == "" {
		versionPath, err := resolver.resolve("VERSION")
		if err != nil {
			t.Fatal(err)
		}
		contents, err := os.ReadFile(versionPath)
		if err != nil {
			t.Fatal(err)
		}
		want = strings.TrimSpace(string(contents))
	}
	version, err := agentTestBinaryVersion(binary)
	if err != nil || version != want {
		t.Fatalf("packaged binary version %q, expected %q: %v", version, want, err)
	}
}
