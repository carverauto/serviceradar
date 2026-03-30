package agent

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
	"time"
)

func TestStageAgentReleaseStagesBinaryArtifact(t *testing.T) {
	binaryData := []byte("#!/bin/sh\necho release\n")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    server.URL + "/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})

	result, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
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
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    server.URL + "/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})
	payload.Signature = base64.StdEncoding.EncodeToString([]byte("invalid-signature"))

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if !errors.Is(err, errReleaseSignatureInvalid) {
		t.Fatalf("expected errReleaseSignatureInvalid, got %v", err)
	}
}

func TestStageAgentReleaseRejectsDigestMismatch(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, []byte("unexpected"))
	defer server.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    server.URL + "/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})
	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if !errors.Is(err, errContentHashMismatch) {
		t.Fatalf("expected errContentHashMismatch, got %v", err)
	}
}

func TestStageAgentReleaseExtractsTarballEntrypoint(t *testing.T) {
	archiveData := buildReleaseArchive(t, "bin/serviceradar-agent", []byte("#!/bin/sh\necho archive\n"))
	server := newArtifactServer(t, archiveData)
	defer server.Close()

	payload := signedReleasePayload(t, archiveData, releaseArtifactPayload{
		URL:        server.URL + "/serviceradar-agent.tar.gz",
		SHA256:     digestHex(archiveData),
		OS:         runtime.GOOS,
		Arch:       runtime.GOARCH,
		Format:     releaseArtifactFormatTarGz,
		Entrypoint: "bin/serviceradar-agent",
	})

	result, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if err != nil {
		t.Fatalf("stageAgentRelease() error = %v", err)
	}

	if got, want := filepath.Base(result.EntrypointPath), releaseDefaultEntrypoint; got != want {
		t.Fatalf("entrypoint basename = %q, want %q", got, want)
	}
}

func TestStageAgentReleaseRejectsUnsignedArtifactMutation(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    server.URL + "/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})
	payload.Artifact.Entrypoint = "evil-agent"

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if !errors.Is(err, errReleaseArtifactNotSigned) {
		t.Fatalf("expected errReleaseArtifactNotSigned, got %v", err)
	}
}

func TestStageAgentReleaseRejectsArtifactPlatformMismatch(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    server.URL + "/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     "other-os",
		Arch:   runtime.GOARCH,
	})

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if !errors.Is(err, errReleaseArtifactPlatformInvalid) {
		t.Fatalf("expected errReleaseArtifactPlatformInvalid, got %v", err)
	}
}

func TestStageAgentReleaseAllowsSameOriginHTTPSRedirects(t *testing.T) {
	binaryData := []byte("binary")
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/redirect":
			http.Redirect(w, r, "/artifact", http.StatusFound)
		case "/artifact":
			http.ServeContent(w, r, "artifact", time.Unix(0, 0), bytes.NewReader(binaryData))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    server.URL + "/redirect",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if err != nil {
		t.Fatalf("expected redirecting download to succeed, got %v", err)
	}
}

func TestStageAgentReleaseRejectsRedirectToDifferentHTTPSHost(t *testing.T) {
	binaryData := []byte("binary")
	artifactServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "artifact", time.Unix(0, 0), bytes.NewReader(binaryData))
	}))
	defer artifactServer.Close()

	redirectServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, artifactServer.URL+"/artifact", http.StatusFound)
	}))
	defer redirectServer.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    redirectServer.URL,
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})

	httpClient := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  httpClient,
	})
	if !errors.Is(err, errReleaseRedirectOriginChanged) {
		t.Fatalf("expected errReleaseRedirectOriginChanged, got %v", err)
	}
}

func TestStageAgentReleaseRejectsRedirectToHTTP(t *testing.T) {
	binaryData := []byte("binary")
	insecureServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "artifact", time.Unix(0, 0), bytes.NewReader(binaryData))
	}))
	defer insecureServer.Close()

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, insecureServer.URL+"/artifact", http.StatusFound)
	}))
	defer server.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    server.URL,
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if !errors.Is(err, errReleaseRedirectInsecure) {
		t.Fatalf("expected errReleaseRedirectInsecure, got %v", err)
	}
}

func TestStageAgentReleaseRejectsGatewayRedirectToDifferentHost(t *testing.T) {
	binaryData := []byte("gateway-binary")
	artifactServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "artifact", time.Unix(0, 0), bytes.NewReader(binaryData))
	}))
	defer artifactServer.Close()

	gatewayServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("X-ServiceRadar-Release-Target-ID"); got != "target-123" {
			t.Fatalf("target header = %q, want %q", got, "target-123")
		}
		if got := r.Header.Get("X-ServiceRadar-Release-Command-ID"); got != "command-123" {
			t.Fatalf("command header = %q, want %q", got, "command-123")
		}
		http.Redirect(w, r, artifactServer.URL+"/artifact", http.StatusFound)
	}))
	defer gatewayServer.Close()

	gatewayURL, err := url.Parse(gatewayServer.URL)
	if err != nil {
		t.Fatalf("url.Parse() error = %v", err)
	}
	port, err := strconv.Atoi(gatewayURL.Port())
	if err != nil {
		t.Fatalf("Atoi() error = %v", err)
	}

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    "https://releases.example.com/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})
	payload.ArtifactTransport = releaseArtifactTransport{
		Kind:     "gateway_https",
		Path:     "/artifacts/releases/download",
		Port:     port,
		TargetID: "target-123",
	}

	httpClient := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	_, err = stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  httpClient,
		GatewayAddr: gatewayURL.Host,
		CommandID:   "command-123",
	})
	if !errors.Is(err, errReleaseRedirectOriginChanged) {
		t.Fatalf("expected errReleaseRedirectOriginChanged, got %v", err)
	}
}

func TestStageAgentReleaseUsesGatewayArtifactTransport(t *testing.T) {
	binaryData := []byte("gateway-binary")
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("X-ServiceRadar-Release-Target-ID"); got != "target-123" {
			t.Fatalf("target header = %q, want %q", got, "target-123")
		}
		if got := r.Header.Get("X-ServiceRadar-Release-Command-ID"); got != "command-123" {
			t.Fatalf("command header = %q, want %q", got, "command-123")
		}
		http.ServeContent(w, r, "artifact", time.Unix(0, 0), bytes.NewReader(binaryData))
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("url.Parse() error = %v", err)
	}
	port, err := strconv.Atoi(serverURL.Port())
	if err != nil {
		t.Fatalf("Atoi() error = %v", err)
	}

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    "https://releases.example.com/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})
	payload.ArtifactTransport = releaseArtifactTransport{
		Kind:     "gateway_https",
		Path:     "/artifacts/releases/download",
		Port:     port,
		TargetID: "target-123",
	}

	_, err = stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
		GatewayAddr: serverURL.Host,
		CommandID:   "command-123",
	})
	if err != nil {
		t.Fatalf("expected gateway transport download to succeed, got %v", err)
	}
}

func signedReleasePayload(t *testing.T, artifactData []byte, artifact releaseArtifactPayload) releaseUpdatePayload {
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
				"url":        artifact.URL,
				"sha256":     digestHex(artifactData),
				"os":         artifact.OS,
				"arch":       artifact.Arch,
				"format":     artifact.Format,
				"entrypoint": artifact.Entrypoint,
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
		Artifact:  artifact,
	}
}

func newArtifactServer(t *testing.T, data []byte) *httptest.Server {
	t.Helper()

	return httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
