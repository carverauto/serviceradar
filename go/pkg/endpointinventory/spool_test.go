package endpointinventory

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWriteSpoolWritesLatestAndRunPayload(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := DefaultConfig()
	cfg.SpoolDir = filepath.Join(tmpDir, "spool")
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")
	cfg.MaxOutputBytes = 1024 * 1024

	payload := &ScanPayload{
		SchemaVersion: SchemaVersion,
		AgentID:       "agent-1",
		ScanID:        "scan-1",
		State:         "scanned",
		CoverageState: "complete",
		LastScanAt:    time.Unix(10, 0).UTC(),
	}

	if err := WriteSpool(cfg, payload); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(cfg.SpoolDir, LatestFileName)); err != nil {
		t.Fatalf("latest spool missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(cfg.SpoolDir, "runs", "scan-1.json")); err != nil {
		t.Fatalf("run spool missing: %v", err)
	}
}

func TestWriteSpoolRejectsOversizePayload(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := DefaultConfig()
	cfg.SpoolDir = filepath.Join(tmpDir, "spool")
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")
	cfg.MaxOutputBytes = 32

	err := WriteSpool(cfg, &ScanPayload{
		SchemaVersion: SchemaVersion,
		AgentID:       "agent-1",
		ScanID:        "scan-1",
		State:         "scanned",
		CoverageState: "complete",
		Metadata:      map[string]any{"padding": "this payload should exceed the tiny test limit"},
	})
	if !errors.Is(err, ErrSpoolPayloadTooLarge) {
		t.Fatalf("err = %v, want ErrSpoolPayloadTooLarge", err)
	}
}

func TestWriteRuntimeProfileIsStable(t *testing.T) {
	tmpDir := t.TempDir()
	profilePath := filepath.Join(tmpDir, "profile", "runtime.json")
	scratchDir := filepath.Join(tmpDir, "tmp")
	enabled := true
	profile := RuntimeProfile{
		Enabled:     &enabled,
		AgentID:     "agent-1",
		ScanTimeout: "5m",
		Sources:     []string{"dpkg"},
	}

	changed, err := WriteRuntimeProfile(profilePath, scratchDir, profile)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("first write should report changed")
	}

	changed, err = WriteRuntimeProfile(profilePath, scratchDir, profile)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("second identical write should not report changed")
	}
}
