package agent

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStageAgentReleaseStagesBinaryArtifact(t *testing.T) {
	payload, binaryData := signedReleasePayload(t, []byte("#!/bin/sh\necho release\n"))
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	payload.Artifact.URL = server.URL + "/serviceradar-agent"

	result, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{RuntimeRoot: t.TempDir()})
	if err != nil {
		t.Fatalf("stageAgentRelease() error = %v", err)
	}

	if got, want := result.Version, payload.Version; got != want {
		t.Fatalf("result.Version = %q, want %q", got, want)
	}
	if _, err := os.Stat(result.EntrypointPath); err != nil {
		t.Fatalf("expected staged entrypoint to exist: %v", err)
	}
	if _, err := os.Stat(filepath.Join(result.VersionDir, releaseMetadataFileName)); err != nil {
		t.Fatalf("expected staged metadata to exist: %v", err)
	}
}

func TestStageAgentReleaseRejectsInvalidSignature(t *testing.T) {
	payload, binaryData := signedReleasePayload(t, []byte("binary"))
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	payload.Artifact.URL = server.URL + "/serviceradar-agent"
	payload.Signature = base64.StdEncoding.EncodeToString([]byte("invalid-signature"))

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{RuntimeRoot: t.TempDir()})
	if !errors.Is(err, errReleaseSignatureInvalid) {
		t.Fatalf("expected errReleaseSignatureInvalid, got %v", err)
	}
}

func TestStageAgentReleaseRejectsDigestMismatch(t *testing.T) {
	payload, binaryData := signedReleasePayload(t, []byte("binary"))
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	payload.Artifact.URL = server.URL + "/serviceradar-agent"
	payload.Artifact.SHA256 = hex.EncodeToString(make([]byte, sha256.Size))

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{RuntimeRoot: t.TempDir()})
	if !errors.Is(err, errContentHashMismatch) {
		t.Fatalf("expected errContentHashMismatch, got %v", err)
	}
}

func TestStageAgentReleaseExtractsTarballEntrypoint(t *testing.T) {
	archiveData := buildReleaseArchive(t, "bin/serviceradar-agent", []byte("#!/bin/sh\necho archive\n"))
	payload, _ := signedReleasePayload(t, archiveData)
	server := newArtifactServer(t, archiveData)
	defer server.Close()

	payload.Artifact.URL = server.URL + "/serviceradar-agent.tar.gz"
	payload.Artifact.Format = releaseArtifactFormatTarGz
	payload.Artifact.SHA256 = digestHex(archiveData)

	result, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{RuntimeRoot: t.TempDir()})
	if err != nil {
		t.Fatalf("stageAgentRelease() error = %v", err)
	}

	if got, want := filepath.Base(result.EntrypointPath), releaseDefaultEntrypoint; got != want {
		t.Fatalf("entrypoint basename = %q, want %q", got, want)
	}
}

func signedReleasePayload(t *testing.T, artifactData []byte) (releaseUpdatePayload, []byte) {
	t.Helper()

	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("ed25519.GenerateKey() error = %v", err)
	}
	t.Setenv(releasePublicKeyEnv, base64.StdEncoding.EncodeToString(publicKey))

	manifest := map[string]interface{}{
		"version": "1.1.0",
		"artifacts": []interface{}{
			map[string]interface{}{
				"os":     "linux",
				"arch":   "amd64",
				"sha256": digestHex(artifactData),
			},
		},
	}

	manifestJSON, err := marshalCanonicalJSON(manifest)
	if err != nil {
		t.Fatalf("marshalCanonicalJSON() error = %v", err)
	}

	signature := ed25519.Sign(privateKey, manifestJSON)

	return releaseUpdatePayload{
		ReleaseID: "release-1",
		RolloutID: "rollout-1",
		TargetID:  "target-1",
		Version:   "1.1.0",
		Manifest:  manifest,
		Signature: base64.StdEncoding.EncodeToString(signature),
		Artifact: releaseArtifactPayload{
			SHA256: digestHex(artifactData),
		},
	}, artifactData
}

func newArtifactServer(t *testing.T, data []byte) *httptest.Server {
	t.Helper()

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "artifact", time.Unix(0, 0), bytes.NewReader(data))
	}))
}

func buildReleaseArchive(t *testing.T, path string, content []byte) []byte {
	t.Helper()

	var archive bytes.Buffer
	gzw := gzip.NewWriter(&archive)
	tw := tar.NewWriter(gzw)

	if err := tw.WriteHeader(&tar.Header{
		Name: path,
		Mode: 0o755,
		Size: int64(len(content)),
	}); err != nil {
		t.Fatalf("WriteHeader() error = %v", err)
	}
	if _, err := tw.Write(content); err != nil {
		t.Fatalf("Write() error = %v", err)
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("tar.Close() error = %v", err)
	}
	if err := gzw.Close(); err != nil {
		t.Fatalf("gzip.Close() error = %v", err)
	}

	return archive.Bytes()
}

func digestHex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
