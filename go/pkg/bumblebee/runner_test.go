package bumblebee

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDiscoverRootsIncludesRootAndAllExistingHomes(t *testing.T) {
	tmpDir := t.TempDir()
	rootHome := filepath.Join(tmpDir, "root")
	aliceHome := filepath.Join(tmpDir, "alice")
	serviceHome := filepath.Join(tmpDir, "svc")
	for _, path := range []string{rootHome, aliceHome, serviceHome} {
		if err := os.MkdirAll(path, 0755); err != nil {
			t.Fatal(err)
		}
	}

	passwd := filepath.Join(tmpDir, "passwd")
	if err := os.WriteFile(passwd, []byte(
		"root:x:0:0:root:"+rootHome+":/bin/bash\n"+
			"alice:x:1000:1000:Alice:"+aliceHome+":/bin/bash\n"+
			"svc:x:998:998:Service:"+serviceHome+":/usr/sbin/nologin\n"+
			"missing:x:1001:1001:Missing:"+filepath.Join(tmpDir, "missing")+":/bin/bash\n",
	), 0600); err != nil {
		t.Fatal(err)
	}

	cfg := DefaultConfig()
	cfg.IncludeRoot = false
	cfg.PasswdPath = passwd
	roots, skipped := DiscoverRoots(cfg)

	want := map[string]bool{rootHome: true, aliceHome: true, serviceHome: true}
	for _, root := range roots {
		delete(want, root.Path)
	}
	if len(want) != 0 {
		t.Fatalf("missing roots: %#v; got %#v", want, roots)
	}
	if len(skipped) != 1 || skipped[0].Path != filepath.Join(tmpDir, "missing") {
		t.Fatalf("unexpected skipped roots: %#v", skipped)
	}
}

func TestParseFindingsAcceptsObjectArray(t *testing.T) {
	findings, err := ParseFindings([]byte(`{
		"findings": [
			{
				"id": "catalog-1",
				"severity": "high",
				"package": "ollama",
				"version": "0.1.0",
				"path": "/home/alice/.ollama"
			}
		]
	}`), 10)
	if err != nil {
		t.Fatal(err)
	}

	if len(findings) != 1 {
		t.Fatalf("len(findings) = %d, want 1", len(findings))
	}
	if findings[0].FindingID == "" {
		t.Fatal("expected generated finding id")
	}
	if findings[0].PackageName != "ollama" || findings[0].Severity != "high" {
		t.Fatalf("unexpected finding: %#v", findings[0])
	}
}
