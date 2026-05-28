package bumblebee

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

type fakeObjectDownloader struct {
	data []byte
}

func (f fakeObjectDownloader) DownloadObject(context.Context, string) ([]byte, error) {
	return append([]byte(nil), f.data...), nil
}

func TestStageCatalogAssignmentVerifiesAndWritesCurrent(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	data := []byte(`{"schema_version":"serviceradar.bumblebee.catalog.v1","entries":[]}`)
	sum := sha256.Sum256(data)
	sha := hex.EncodeToString(sum[:])

	result, err := StageCatalogAssignment(
		context.Background(),
		fakeObjectDownloader{data: data},
		filepath.Join(dir, "catalog", "current"),
		filepath.Join(dir, "tmp"),
		CatalogAssignment{
			SnapshotRef: "bumblebee:test:v1",
			ObjectKey:   "bumblebee/catalogs/test/catalog.json",
			SHA256:      sha,
		},
	)
	if err != nil {
		t.Fatalf("StageCatalogAssignment() error = %v", err)
	}
	if !result.Changed {
		t.Fatal("expected changed result")
	}

	current, err := os.ReadFile(filepath.Join(dir, "catalog", "current"))
	if err != nil {
		t.Fatalf("read current catalog: %v", err)
	}
	if string(current) != string(data) {
		t.Fatalf("current catalog = %q, want %q", current, data)
	}

	metadata, err := LoadCatalogAssignmentMetadata(filepath.Join(dir, "catalog", "current"))
	if err != nil {
		t.Fatalf("LoadCatalogAssignmentMetadata() error = %v", err)
	}
	if metadata.SnapshotRef != "bumblebee:test:v1" {
		t.Fatalf("metadata.SnapshotRef = %q", metadata.SnapshotRef)
	}
}

func TestStageCatalogAssignmentRejectsHashMismatch(t *testing.T) {
	t.Parallel()

	_, err := StageCatalogAssignment(
		context.Background(),
		fakeObjectDownloader{data: []byte(`{}`)},
		filepath.Join(t.TempDir(), "current"),
		t.TempDir(),
		CatalogAssignment{
			SnapshotRef: "bumblebee:test:v1",
			ObjectKey:   "bumblebee/catalogs/test/catalog.json",
			SHA256:      "not-the-real-hash",
		},
	)
	if err == nil {
		t.Fatal("expected hash mismatch")
	}
}
