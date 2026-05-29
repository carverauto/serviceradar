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
				"record_type": "scan_summary",
				"status": "complete"
			},
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

func TestParseFindingsSkipsUpstreamNonFindingRecords(t *testing.T) {
	data := []byte(`
{"record_type":"package","record_id":"pkg-1","package_name":"leftpad","version":"1.0.0"}
{"record_type":"finding","record_id":"finding-1","catalog_id":"cat-1","severity":"critical","ecosystem":"npm","package_name":"leftpad","version":"1.0.0","source_file":"/home/alice/package-lock.json"}
{"record_type":"scan_summary","record_id":"summary-1","status":"complete","findings_emitted":1}
`)

	findings, err := ParseFindings(data, 10)
	if err != nil {
		t.Fatal(err)
	}

	if len(findings) != 1 {
		t.Fatalf("len(findings) = %d, want 1", len(findings))
	}
	if findings[0].ID != "finding-1" || findings[0].FindingID != "finding-1" {
		t.Fatalf("unexpected ids: %#v", findings[0])
	}
	if findings[0].CatalogID != "cat-1" || findings[0].PackageName != "leftpad" {
		t.Fatalf("unexpected finding: %#v", findings[0])
	}
}

func TestParseFindingsSanitizesSpoolSafeFields(t *testing.T) {
	data := []byte(`{
		"record_type": "finding",
		"record_id": "finding-1",
		"catalog_id": "cat-1",
		"severity": "critical",
		"ecosystem": "npm",
		"package_name": "leftpad",
		"version": "1.0.0",
		"source_file": "/home/alice/work/package-lock.json",
		"project_path": "/root/private/project",
		"endpoint": {"username": "alice", "uid": 1000, "hostname": "laptop"},
		"username": "alice",
		"uid": 1000
	}`)

	findings, err := ParseFindings(data, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(findings) != 1 {
		t.Fatalf("len(findings) = %d, want 1", len(findings))
	}

	finding := findings[0]
	if got := finding.Evidence["source_file"]; got != "~/work/package-lock.json" {
		t.Fatalf("sanitized source_file = %#v", got)
	}
	if got := finding.Evidence["project_path"]; got != "~root/private/project" {
		t.Fatalf("sanitized project_path = %#v", got)
	}
	if _, ok := finding.Metadata["endpoint"]; ok {
		t.Fatalf("endpoint identity leaked into metadata: %#v", finding.Metadata)
	}
	if _, ok := finding.Metadata["username"]; ok {
		t.Fatalf("username leaked into metadata: %#v", finding.Metadata)
	}
	if _, ok := finding.Metadata["uid"]; ok {
		t.Fatalf("uid leaked into metadata: %#v", finding.Metadata)
	}
}
