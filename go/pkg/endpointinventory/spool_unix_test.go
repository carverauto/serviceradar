//go:build !windows

package endpointinventory

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// TestSharedStateDirsAreGroupWritable guards against regressing the
// endpoint-inventory ownership bug: the scanner runs as root while the agent
// runs as the unprivileged serviceradar user, and they share the spool, cache,
// tmp, and profile dirs. If those dirs are created without the group-write bit,
// the agent can no longer write upload-success markers (or clear
// pending-upload.json), and uploads get stuck across the 12h scan cadence.
func TestSharedStateDirsAreGroupWritable(t *testing.T) {
	// Pin umask to 0 so the assertion reflects the mode the code requests, not
	// the test runner's ambient umask.
	oldUmask := syscall.Umask(0)
	t.Cleanup(func() { syscall.Umask(oldUmask) })

	tmpDir := t.TempDir()
	cfg := DefaultConfig()
	cfg.SpoolDir = filepath.Join(tmpDir, "spool")
	cfg.CacheDir = filepath.Join(tmpDir, "cache")
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")
	cfg.MaxOutputBytes = 1024 * 1024
	cfg.AgentID = "agent-1"

	payload := &ScanPayload{
		SchemaVersion: SchemaVersion,
		AgentID:       "agent-1",
		ScanID:        "scan-1",
		State:         "scanned",
		CoverageState: "complete",
		LastScanAt:    time.Unix(10, 0).UTC(),
	}
	if err := WriteSpool(cfg, payload); err != nil {
		t.Fatalf("WriteSpool: %v", err)
	}
	if err := WriteCacheManifest(cfg, &InventoryCacheManifest{SchemaVersion: CacheVersion, AgentID: "agent-1"}); err != nil {
		t.Fatalf("WriteCacheManifest: %v", err)
	}

	profilePath := filepath.Join(tmpDir, "profile", "runtime.json")
	if _, err := WriteRuntimeProfile(profilePath, cfg.TmpDir, RuntimeProfile{AgentID: "agent-1"}); err != nil {
		t.Fatalf("WriteRuntimeProfile: %v", err)
	}

	const groupWrite = 0o020
	dirs := []string{
		cfg.SpoolDir,
		filepath.Join(cfg.SpoolDir, "runs"),
		cfg.CacheDir,
		cfg.TmpDir,
		filepath.Dir(profilePath),
	}
	for _, dir := range dirs {
		info, err := os.Stat(dir)
		if err != nil {
			t.Fatalf("stat %s: %v", dir, err)
		}
		if info.Mode().Perm()&groupWrite == 0 {
			t.Errorf("dir %s mode = %#o, want group-writable (the non-root serviceradar agent must be able to write markers)", dir, info.Mode().Perm())
		}
	}
}
