package bumblebee

import (
	"context"
	"encoding/json"
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

func boolPtr(value bool) *bool    { return &value }
func intPtr(value int) *int       { return &value }
func int64Ptr(value int64) *int64 { return &value }

func TestRootCoverageNotRequiredWhenRootDisabled(t *testing.T) {
	cfg := DefaultConfig()
	cfg.IncludeRoot = false

	if rootCoverageRequired(cfg) {
		t.Fatal("root coverage should not be required when include_root is false")
	}

	cfg.IncludeRoot = true
	cfg.ExcludeRoots = []string{"/root"}
	if rootCoverageRequired(cfg) {
		t.Fatal("root coverage should not be required when /root is excluded")
	}
}

func TestAppendDedupedFindingsAppliesLimitAfterDedup(t *testing.T) {
	existing := make([]Finding, 0, 3)

	firstRoot := []Finding{
		{FindingID: "duplicate", PackageName: "pkg-a"},
		{FindingID: "duplicate", PackageName: "pkg-a"},
		{FindingID: "unique-1", PackageName: "pkg-b"},
	}
	secondRoot := []Finding{
		{FindingID: "unique-2", PackageName: "pkg-c"},
		{FindingID: "unique-3", PackageName: "pkg-d"},
	}

	findings := appendDedupedFindings(existing, firstRoot)
	if len(findings) != 2 {
		t.Fatalf("len(findings) after first root = %d, want 2", len(findings))
	}

	findings = appendDedupedFindings(findings, secondRoot)
	if len(findings) < 3 {
		t.Fatalf("dedupe should leave room for later unique findings, got %#v", findings)
	}
}

func TestLoadConfigAppliesRuntimeProfile(t *testing.T) {
	dir := t.TempDir()
	profilePath := filepath.Join(dir, "profile", "runtime.json")
	if err := os.MkdirAll(filepath.Dir(profilePath), 0755); err != nil {
		t.Fatal(err)
	}
	profile := RuntimeProfile{
		Enabled:          boolPtr(true),
		AgentID:          "agent-runtime",
		ScanTimeout:      "2m",
		IncludeHomeRoots: boolPtr(false),
		IncludeRoot:      boolPtr(false),
		ExplicitRoots:    []string{dir},
		Ecosystems:       []string{"npm"},
		MaxFindings:      intPtr(7),
		MaxOutputBytes:   int64Ptr(1024),
	}
	data, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(profilePath, data, 0600); err != nil {
		t.Fatal(err)
	}

	configPath := filepath.Join(dir, "bumblebee-scan.json")
	base := DefaultConfig()
	base.ProfilePath = profilePath
	base.Enabled = false
	base.AgentID = "base-agent"
	base.ExplicitRoots = nil
	configData, err := json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, configData, 0600); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(configPath)
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}
	if !cfg.Enabled || cfg.AgentID != "agent-runtime" {
		t.Fatalf("runtime profile did not override enablement/agent: %#v", cfg)
	}
	if cfg.IncludeHomeRoots || cfg.IncludeRoot {
		t.Fatalf("runtime profile did not override root discovery: %#v", cfg)
	}
	if cfg.ScanTimeout != "2m" || cfg.MaxFindings != 7 || cfg.MaxOutputBytes != 1024 {
		t.Fatalf("runtime profile did not override limits: %#v", cfg)
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

func TestRunDisabledStampsScannerVersion(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = false

	payload, err := NewRunner(cfg, "0.1.8").Run(context.Background())
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	if payload.State != stateNotScanned {
		t.Fatalf("state = %q, want %s", payload.State, stateNotScanned)
	}
	assertStampedScannerVersion(t, payload, "0.1.8")

	unstamped, err := NewRunner(cfg, "").Run(context.Background())
	if err != nil {
		t.Fatalf("Run() empty version error = %v", err)
	}
	if unstamped.ScannerVersion != "" {
		t.Fatalf("ScannerVersion = %q, want empty", unstamped.ScannerVersion)
	}
	encoded, err := json.Marshal(unstamped)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, ok := decoded["scanner_version"]; ok {
		t.Fatalf("empty build version must omit scanner_version, got %#v", decoded["scanner_version"])
	}
	if got, _ := unstamped.Metadata["upstream_scanner_version"].(string); got != "v0.1.1" {
		t.Fatalf("upstream_scanner_version = %#v, want v0.1.1", unstamped.Metadata["upstream_scanner_version"])
	}

	noRoots := DefaultConfig()
	noRoots.Enabled = true
	noRoots.IncludeRoot = false
	noRoots.IncludeHomeRoots = false
	noRoots.ExplicitRoots = nil
	zeroRoots, err := NewRunner(noRoots, "0.1.8").Run(context.Background())
	if err != nil {
		t.Fatalf("Run() zero roots error = %v", err)
	}
	if zeroRoots.State != stateScanFailed || zeroRoots.AttemptedRootCount != 0 {
		t.Fatalf("zero-root result = state %q attempted %d", zeroRoots.State, zeroRoots.AttemptedRootCount)
	}
	assertStampedScannerVersion(t, zeroRoots, "0.1.8")
}

func assertStampedScannerVersion(t *testing.T, payload *ScanPayload, buildVersion string) {
	t.Helper()
	if payload.ScannerVersion != buildVersion {
		t.Fatalf("ScannerVersion = %q, want %s", payload.ScannerVersion, buildVersion)
	}
	if got, _ := payload.Metadata["upstream_scanner_version"].(string); got != "v0.1.1" {
		t.Fatalf("upstream_scanner_version = %#v, want v0.1.1", payload.Metadata["upstream_scanner_version"])
	}
}
