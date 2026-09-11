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

	arm64Path := filepath.Join(t.TempDir(), "arm64-runtime.tar.gz")
	arm64Bytes := []byte("distinct synthetic ARM64 runtime archive")
	if err := os.WriteFile(arm64Path, arm64Bytes, 0o600); err != nil {
		t.Fatal(err)
	}

	tempDir, assets, err := buildManagedAgentManifestAssets(
		"1.2.6",
		[]managedAgentRuntime{
			{arch: "arm64", url: "https://downloads.example.com/agent_arm64.tar.gz", path: arm64Path},
			{arch: defaultAgentRuntimeArch, url: "https://downloads.example.com/agent_amd64.tar.gz", path: runtimeArtifactPath},
		},
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

	manifest := readVerifiedManagedManifest(t, tempDir, publicKey)
	if manifest.Version != "1.2.6" {
		t.Fatalf("manifest version = %q, want %q", manifest.Version, "1.2.6")
	}
	if len(manifest.Artifacts) != 2 {
		t.Fatalf("manifest artifacts = %d, want 2", len(manifest.Artifacts))
	}

	if manifest.Artifacts[1].SHA256 != digestBytes(arm64Bytes) {
		t.Fatal("ARM64 manifest digest does not match its distinct runtime")
	}

	artifact := manifest.Artifacts[0]
	if artifact.URL != "https://downloads.example.com/agent_amd64.tar.gz" || artifact.Arch != defaultAgentRuntimeArch ||
		manifest.Artifacts[1].Arch != "arm64" || manifest.Artifacts[1].URL != "https://downloads.example.com/agent_arm64.tar.gz" {
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
}

func readVerifiedManagedManifest(t *testing.T, tempDir string, publicKey ed25519.PublicKey) agentReleaseManifest {
	t.Helper()
	manifestBytes, err := os.ReadFile(filepath.Join(tempDir, defaultAgentManifestAssetName))
	if err != nil {
		t.Fatalf("ReadFile(manifest) error = %v", err)
	}
	var manifest agentReleaseManifest
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		t.Fatalf("Unmarshal(manifest) error = %v", err)
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
	return manifest
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

func TestUploadAssetGitHubSetsContentLength(t *testing.T) {
	const assetName = "serviceradar-agent-1.4.35-1-1.4.35-1.x86_64.rpm"
	assetContent := []byte("fake rpm bytes")
	uploadPath := filepath.Join(t.TempDir(), assetName)
	if err := os.WriteFile(uploadPath, assetContent, 0o644); err != nil {
		t.Fatalf("WriteFile(upload asset) error = %v", err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s, want POST", r.Method)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			t.Fatalf("authorization header = %q", got)
		}
		if got := r.Header.Get("Content-Type"); got != "application/octet-stream" {
			t.Fatalf("content-type = %q", got)
		}
		if r.ContentLength != int64(len(assetContent)) {
			t.Fatalf("content-length = %d, want %d", r.ContentLength, len(assetContent))
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("ReadAll(body) error = %v", err)
		}
		if string(body) != string(assetContent) {
			t.Fatalf("uploaded body = %q", body)
		}
		w.WriteHeader(http.StatusCreated)
	}))
	t.Cleanup(server.Close)

	client := &githubClient{
		token:   "test-token",
		http:    server.Client(),
		baseURL: "https://api.github.com",
		repo:    "carverauto/serviceradar",
	}
	if err := client.uploadAsset(server.URL+"/repos/carverauto/serviceradar/releases/1/assets{?name,label}", uploadPath, assetName); err != nil {
		t.Fatalf("uploadAsset() error = %v", err)
	}
}

func TestEnsureReleaseDoesNotPatchTargetCommitish(t *testing.T) {
	var patchBody []byte
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/releases/tags/"):
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"message":"Not Found"}`))
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/releases"):
			_ = json.NewEncoder(w).Encode([]release{{
				ID:              42,
				TagName:         "v1.4.35",
				Name:            "ServiceRadar v1.4.35",
				Draft:           true,
				Prerelease:      true,
				TargetCommitish: "staging",
				UploadURL:       "https://example.test/assets",
			}})
		case r.Method == http.MethodPatch:
			body, err := io.ReadAll(r.Body)
			if err != nil {
				t.Errorf("ReadAll(patch) error = %v", err)
			}
			patchBody = body
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(body)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)

	client := &githubClient{
		token:   "test-token",
		http:    server.Client(),
		baseURL: "https://api.github.com",
		repo:    "carverauto/serviceradar",
	}
	client.baseURL = server.URL

	rel, created, err := ensureRelease(client, ensureReleaseArgs{
		tag:        "v1.4.35",
		name:       "ServiceRadar v1.4.35",
		commit:     "29c9c2b25813b042b074f54f4951d33801317869",
		notes:      "updated notes",
		draft:      true,
		prerelease: false,
	})
	if err != nil {
		t.Fatalf("ensureRelease() error = %v", err)
	}
	if created {
		t.Fatal("ensureRelease() created a release, want update of existing draft")
	}
	if rel == nil || rel.ID != 42 && rel.TagName != "v1.4.35" {
		// updateRelease decodes the patch body, which has no id; tag is enough.
		if rel == nil || rel.TagName != "v1.4.35" {
			t.Fatalf("ensureRelease() release = %+v", rel)
		}
	}
	if len(patchBody) == 0 {
		t.Fatal("expected a PATCH body")
	}
	if strings.Contains(string(patchBody), "target_commitish") {
		t.Fatalf("PATCH must omit target_commitish when the git tag exists; body=%s", patchBody)
	}
}

func TestGetReleaseAssetDownloadURLUsesPublishedGitHubTagPath(t *testing.T) {
	client := &githubClient{
		baseURL: "https://api.github.com",
		repo:    "carverauto/serviceradar",
		dryRun:  true,
	}

	got, err := client.getReleaseAssetDownloadURL("v1.4.39", "serviceradar-agent_1.4.39_linux_amd64.tar.gz")
	if err != nil {
		t.Fatalf("getReleaseAssetDownloadURL() error = %v", err)
	}

	want := "https://github.com/carverauto/serviceradar/releases/download/v1.4.39/serviceradar-agent_1.4.39_linux_amd64.tar.gz"
	if got != want {
		t.Fatalf("getReleaseAssetDownloadURL() = %q, want %q", got, want)
	}
}
