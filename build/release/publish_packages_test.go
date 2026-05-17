package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
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
		managedAgentManifestOptions{},
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

func TestBuildManagedAgentManifestAssetsWithRDPBundle(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey() error = %v", err)
	}
	t.Setenv(releasePrivateKeyEnv, base64.StdEncoding.EncodeToString(privateKey))

	tempRoot := t.TempDir()
	runtimeArtifactPath := filepath.Join(tempRoot, "serviceradar-agent-release-runtime.tar.gz")
	runtimeArtifact := []byte("fake-runtime-archive")
	if err := os.WriteFile(runtimeArtifactPath, runtimeArtifact, 0o644); err != nil {
		t.Fatalf("WriteFile(runtime artifact) error = %v", err)
	}

	rdpRuntimeArtifactPath := filepath.Join(tempRoot, "serviceradar-agent-rdp-release-runtime.tar.gz")
	rdpRuntimeArtifact := []byte("fake-rdp-runtime-archive")
	if err := os.WriteFile(rdpRuntimeArtifactPath, rdpRuntimeArtifact, 0o644); err != nil {
		t.Fatalf("WriteFile(rdp runtime artifact) error = %v", err)
	}

	tempDir, assets, err := buildManagedAgentManifestAssets(
		"1.2.6",
		"https://code.carverauto.dev/attachments/runtime.tar.gz",
		runtimeArtifactPath,
		false,
		managedAgentManifestOptions{
			RDPRuntimeURL:          "https://code.carverauto.dev/attachments/runtime-rdp.tar.gz",
			RDPRuntimeArtifactPath: rdpRuntimeArtifactPath,
		},
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
	if len(manifest.Artifacts) != 2 {
		t.Fatalf("manifest artifacts = %d, want 2", len(manifest.Artifacts))
	}

	rdpArtifact := manifest.Artifacts[0]
	if rdpArtifact.URL != "https://code.carverauto.dev/attachments/runtime-rdp.tar.gz" {
		t.Fatalf("rdp artifact URL = %q", rdpArtifact.URL)
	}
	if got := strings.Join(rdpArtifact.Capabilities, ","); got != "agent,remote_access.rdp" {
		t.Fatalf("rdp artifact Capabilities = %q", got)
	}
	if rdpArtifact.HelperProtocolVersion != defaultRDPHelperProtocolVersion {
		t.Fatalf("rdp artifact HelperProtocolVersion = %q", rdpArtifact.HelperProtocolVersion)
	}
	if rdpArtifact.DeploymentRequirements["helper"] != defaultRDPHelperBinary {
		t.Fatalf("rdp artifact helper requirement = %v", rdpArtifact.DeploymentRequirements["helper"])
	}
	if rdpArtifact.DeploymentRequirements["helper_connector_ready"] != false ||
		rdpArtifact.DeploymentRequirements["helper_connector_ready_reason"] != defaultRDPConnectorReadyReason ||
		rdpArtifact.DeploymentRequirements["requires_helper_readiness_probe"] != true ||
		rdpArtifact.DeploymentRequirements["release_phase"] != "experimental" {
		t.Fatalf("rdp artifact deployment requirements = %#v", rdpArtifact.DeploymentRequirements)
	}
	if rdpArtifact.Checksums["sha256"] != digestBytes(rdpRuntimeArtifact) {
		t.Fatalf("rdp artifact checksum = %q", rdpArtifact.Checksums["sha256"])
	}

	baseArtifact := manifest.Artifacts[1]
	if got := strings.Join(baseArtifact.Capabilities, ","); got != "agent" {
		t.Fatalf("base artifact Capabilities = %q", got)
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
