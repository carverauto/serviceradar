package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManagedAgentReleasePrivateKeyFromSeed(t *testing.T) {
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey() error = %v", err)
	}

	t.Setenv(releasePrivateKeyEnv, hex.EncodeToString(privateKey.Seed()))

	resolved, err := managedAgentReleasePrivateKey()
	if err != nil {
		t.Fatalf("managedAgentReleasePrivateKey() error = %v", err)
	}
	if string(resolved) != string(privateKey) {
		t.Fatalf("managedAgentReleasePrivateKey() mismatch")
	}
}

func TestManagedAgentReleasePrivateKeyFromExpandedKey(t *testing.T) {
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey() error = %v", err)
	}

	t.Setenv(releasePrivateKeyEnv, base64.StdEncoding.EncodeToString(privateKey))

	resolved, err := managedAgentReleasePrivateKey()
	if err != nil {
		t.Fatalf("managedAgentReleasePrivateKey() error = %v", err)
	}
	if string(resolved) != string(privateKey) {
		t.Fatalf("managedAgentReleasePrivateKey() mismatch")
	}
}

func TestBuildManagedAgentManifestAssets(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey() error = %v", err)
	}
	t.Setenv(releasePrivateKeyEnv, base64.StdEncoding.EncodeToString(privateKey))

	runtimeArtifactPath := filepath.Join(t.TempDir(), "serviceradar-agent-release-runtime.tar.gz")
	runtimeArtifact := []byte("fake-runtime-archive")
	if err := os.WriteFile(runtimeArtifactPath, runtimeArtifact, 0o644); err != nil {
		t.Fatalf("WriteFile(runtime artifact) error = %v", err)
	}

	tempDir, assets, err := buildManagedAgentManifestAssets(
		"1.2.6",
		"https://code.carverauto.dev/attachments/runtime.tar.gz",
		runtimeArtifactPath,
		false,
	)
	if err != nil {
		t.Fatalf("buildManagedAgentManifestAssets() error = %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(tempDir)
	})

	if len(assets) != 2 {
		t.Fatalf("buildManagedAgentManifestAssets() returned %d assets, want 2", len(assets))
	}

	manifestBytes, err := os.ReadFile(filepath.Join(tempDir, defaultAgentManifestAssetName))
	if err != nil {
		t.Fatalf("ReadFile(manifest) error = %v", err)
	}
	var manifest agentReleaseManifest
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		t.Fatalf("Unmarshal(manifest) error = %v", err)
	}
	if manifest.Version != "1.2.6" {
		t.Fatalf("manifest version = %q, want %q", manifest.Version, "1.2.6")
	}
	if len(manifest.Artifacts) != 1 {
		t.Fatalf("manifest artifacts = %d, want 1", len(manifest.Artifacts))
	}

	artifact := manifest.Artifacts[0]
	if artifact.URL != "https://code.carverauto.dev/attachments/runtime.tar.gz" {
		t.Fatalf("artifact URL = %q", artifact.URL)
	}
	digest := sha256.Sum256(runtimeArtifact)
	if artifact.SHA256 != hex.EncodeToString(digest[:]) {
		t.Fatalf("artifact SHA256 = %q", artifact.SHA256)
	}
	if len(artifact.Capabilities) != 1 || artifact.Capabilities[0] != "agent" {
		t.Fatalf("artifact Capabilities = %v, want [agent]", artifact.Capabilities)
	}
	if artifact.Checksums["sha256"] != artifact.SHA256 {
		t.Fatalf("artifact Checksums[sha256] = %q, want artifact SHA256", artifact.Checksums["sha256"])
	}

	signatureValue, err := os.ReadFile(filepath.Join(tempDir, defaultAgentManifestSigAssetName))
	if err != nil {
		t.Fatalf("ReadFile(signature) error = %v", err)
	}
	signatureBytes, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(signatureValue)))
	if err != nil {
		t.Fatalf("DecodeString(signature) error = %v", err)
	}

	var manifestMap map[string]interface{}
	if err := json.Unmarshal(manifestBytes, &manifestMap); err != nil {
		t.Fatalf("Unmarshal(manifest map) error = %v", err)
	}
	canonicalJSON, err := marshalCanonicalJSON(manifestMap)
	if err != nil {
		t.Fatalf("marshalCanonicalJSON() error = %v", err)
	}
	if !ed25519.Verify(publicKey, canonicalJSON, signatureBytes) {
		t.Fatalf("signature verification failed")
	}
}

func TestAssetUploadEndpointUsesConfiguredForgejoBaseURL(t *testing.T) {
	client := &githubClient{
		baseURL: "http://forgejo-http.forgejo.svc.cluster.local:3000",
		repo:    "carverauto/serviceradar",
	}

	got, err := client.assetUploadEndpoint(
		"https://code.carverauto.dev/api/v1/repos/carverauto/serviceradar/releases/362/assets{?name,label}",
		"serviceradar-agent-gateway.rpm",
	)
	if err != nil {
		t.Fatalf("assetUploadEndpoint() error = %v", err)
	}

	want := "http://forgejo-http.forgejo.svc.cluster.local:3000/api/v1/repos/carverauto/serviceradar/releases/362/assets?name=serviceradar-agent-gateway.rpm"
	if got != want {
		t.Fatalf("assetUploadEndpoint() = %q, want %q", got, want)
	}
}

func digestBytes(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func TestUploadAssetUsesForgejoMultipartAttachment(t *testing.T) {
	const assetName = "serviceradar-agent-gateway-1.2.57-1-1.2.57-1.x86_64.rpm"
	const assetContent = "fake rpm bytes"

	uploadPath := filepath.Join(t.TempDir(), assetName)
	if err := os.WriteFile(uploadPath, []byte(assetContent), 0o644); err != nil {
		t.Fatalf("WriteFile(upload asset) error = %v", err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s, want POST", r.Method)
		}
		if got := r.URL.Query().Get("name"); got != assetName {
			t.Fatalf("query name = %q, want %q", got, assetName)
		}
		if got := r.Header.Get("Authorization"); got != "token test-token" {
			t.Fatalf("authorization header = %q", got)
		}

		reader, err := r.MultipartReader()
		if err != nil {
			t.Fatalf("MultipartReader() error = %v", err)
		}
		part, err := reader.NextPart()
		if err != nil {
			t.Fatalf("NextPart() error = %v", err)
		}
		if got := part.FormName(); got != "attachment" {
			t.Fatalf("form field = %q, want attachment", got)
		}
		if got := part.FileName(); got != assetName {
			t.Fatalf("file name = %q, want %q", got, assetName)
		}
		body, err := io.ReadAll(part)
		if err != nil {
			t.Fatalf("ReadAll(part) error = %v", err)
		}
		if string(body) != assetContent {
			t.Fatalf("uploaded body = %q, want %q", string(body), assetContent)
		}
		w.WriteHeader(http.StatusCreated)
	}))
	t.Cleanup(server.Close)

	client := &githubClient{
		token:   "test-token",
		http:    server.Client(),
		baseURL: server.URL,
		repo:    "carverauto/serviceradar",
	}
	if err := client.uploadAsset(server.URL+"/api/v1/repos/carverauto/serviceradar/releases/1/assets{?name}", uploadPath, assetName); err != nil {
		t.Fatalf("uploadAsset() error = %v", err)
	}
}
