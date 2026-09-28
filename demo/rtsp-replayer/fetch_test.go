package replayer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testLogger() *log.Logger {
	return log.New(&strings.Builder{}, "", 0)
}

func shaOf(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func testLock(clips ...Clip) *Lock {
	return &Lock{Version: 1, Bucket: "b", Clips: clips}
}

func testClip(name, body string) Clip {
	return Clip{
		Name: name, Key: name + ".mp4", SHA256: shaOf(body),
		DurationSeconds: 10, Width: 16, Height: 16,
		License: "x", SourceURL: "y",
	}
}

func TestEnsureClipsDownloadsMissing(t *testing.T) {
	fake := &fakeS3{t: t, objects: map[string][]byte{"a.mp4": []byte("AAA")}}
	srv := httptest.NewServer(http.HandlerFunc(fake.handler))
	defer srv.Close()

	s3 := &S3Client{Endpoint: srv.URL, Bucket: "b", Region: "r", AccessKey: "A", SecretKey: "S", HTTP: srv.Client()}
	dir := t.TempDir()
	lock := testLock(testClip("a", "AAA"))

	if err := EnsureClips(context.Background(), testLogger(), s3, lock, dir, true); err != nil {
		t.Fatalf("EnsureClips: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "a.mp4"))
	if err != nil || string(raw) != "AAA" {
		t.Fatalf("downloaded content = %q, err = %v", raw, err)
	}
	if fake.gets != 1 {
		t.Fatalf("gets = %d, want 1", fake.gets)
	}

	// Second run keeps the verified file without re-downloading.
	if err := EnsureClips(context.Background(), testLogger(), s3, lock, dir, true); err != nil {
		t.Fatalf("EnsureClips again: %v", err)
	}
	if fake.gets != 1 {
		t.Fatalf("gets = %d after second run, want still 1", fake.gets)
	}
}

func TestEnsureClipsRefetchesCorruptLocal(t *testing.T) {
	fake := &fakeS3{t: t, objects: map[string][]byte{"a.mp4": []byte("AAA")}}
	srv := httptest.NewServer(http.HandlerFunc(fake.handler))
	defer srv.Close()

	s3 := &S3Client{Endpoint: srv.URL, Bucket: "b", Region: "r", AccessKey: "A", SecretKey: "S", HTTP: srv.Client()}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.mp4"), []byte("CORRUPT"), 0o644); err != nil {
		t.Fatal(err)
	}
	lock := testLock(testClip("a", "AAA"))

	if err := EnsureClips(context.Background(), testLogger(), s3, lock, dir, false); err != nil {
		t.Fatalf("EnsureClips: %v", err)
	}
	raw, _ := os.ReadFile(filepath.Join(dir, "a.mp4"))
	if string(raw) != "AAA" {
		t.Fatalf("content = %q, want refetched AAA", raw)
	}
}

func TestEnsureClipsRefusesDigestMismatch(t *testing.T) {
	fake := &fakeS3{t: t, objects: map[string][]byte{"a.mp4": []byte("EVIL")}}
	srv := httptest.NewServer(http.HandlerFunc(fake.handler))
	defer srv.Close()

	s3 := &S3Client{Endpoint: srv.URL, Bucket: "b", Region: "r", AccessKey: "A", SecretKey: "S", HTTP: srv.Client()}
	dir := t.TempDir()
	lock := testLock(testClip("a", "AAA"))

	err := EnsureClips(context.Background(), testLogger(), s3, lock, dir, false)
	if err == nil || !strings.Contains(err.Error(), "digest mismatch") {
		t.Fatalf("expected digest mismatch error, got %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(dir, "a.mp4")); !os.IsNotExist(statErr) {
		t.Fatalf("mismatched download was installed")
	}
	leftovers, _ := filepath.Glob(filepath.Join(dir, ".clip-*"))
	if len(leftovers) != 0 {
		t.Fatalf("temp files left behind: %v", leftovers)
	}
}

func TestEnsureClipsStrictRefusesUnlisted(t *testing.T) {
	fake := &fakeS3{t: t, objects: map[string][]byte{"a.mp4": []byte("AAA"), "intruder.mp4": []byte("x")}}
	srv := httptest.NewServer(http.HandlerFunc(fake.handler))
	defer srv.Close()

	s3 := &S3Client{Endpoint: srv.URL, Bucket: "b", Region: "r", AccessKey: "A", SecretKey: "S", HTTP: srv.Client()}
	dir := t.TempDir()
	lock := testLock(testClip("a", "AAA"))

	err := EnsureClips(context.Background(), testLogger(), s3, lock, dir, true)
	if err == nil || !strings.Contains(err.Error(), "intruder.mp4") {
		t.Fatalf("expected unlisted-object error naming intruder.mp4, got %v", err)
	}
	if fake.gets != 0 {
		t.Fatalf("strict mode downloaded %d objects before refusing", fake.gets)
	}

	// Non-strict mode ignores the extra object.
	if err := EnsureClips(context.Background(), testLogger(), s3, lock, dir, false); err != nil {
		t.Fatalf("non-strict EnsureClips: %v", err)
	}
}
