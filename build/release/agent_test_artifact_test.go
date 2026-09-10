package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const syntheticTestCommit = "0123456789abcdef0123456789abcdef01234567"

func TestMain(m *testing.M) {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		if os.Getenv(releasePrivateKeyEnv) != "" || os.Getenv("AGENT_TEST_SECRET") != "" {
			os.Exit(2)
		}
		_, _ = fmt.Fprintln(os.Stdout, "3.2.1-test.synthetic")
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func testAgentMetadata(t *testing.T) agentTestArtifactMetadata {
	t.Helper()
	metadata, err := agentTestMetadata(agentTestArtifactConfig{
		expectedCommit: syntheticTestCommit,
		workflowCommit: syntheticTestCommit,
		baseURL:        "https://artifacts.example.com/agent-tests/",
	}, "3.2.1")
	if err != nil {
		t.Fatal(err)
	}
	return metadata
}

func TestAgentTestMetadataBindsReviewedCommitAndSafeURL(t *testing.T) {
	metadata := testAgentMetadata(t)
	if metadata.Version != "3.2.1-test.sha0123456789ab" {
		t.Fatalf("wrong version: %q", metadata.Version)
	}
	wantName := "serviceradar-agent_" + metadata.Version + "_linux_amd64.tar.gz"
	if metadata.ArtifactName != wantName || metadata.ArtifactURL != "https://artifacts.example.com/agent-tests/"+syntheticTestCommit+"/"+wantName {
		t.Fatalf("unexpected artifact metadata: %+v", metadata)
	}
	for _, version := range []string{"v3.2.1", "3.2", "3.2.1-rc.1", "03.2.1", "3.2.1+build"} {
		_, err := agentTestMetadata(agentTestArtifactConfig{expectedCommit: syntheticTestCommit, workflowCommit: syntheticTestCommit}, version)
		if !errors.Is(err, errAgentTestVersion) {
			t.Errorf("version %q accepted: %v", version, err)
		}
	}
	for _, commit := range []string{"", syntheticTestCommit[:12], strings.Repeat("a", 40), strings.ToUpper(syntheticTestCommit)} {
		_, err := agentTestMetadata(agentTestArtifactConfig{expectedCommit: commit, workflowCommit: syntheticTestCommit}, "3.2.1")
		if !errors.Is(err, errAgentTestCommit) {
			t.Errorf("commit %q accepted: %v", commit, err)
		}
	}
}

func TestAgentTestMetadataKeepsLeadingZeroCommitPrefixAlphanumeric(t *testing.T) {
	commit := "001234567890" + strings.Repeat("a", 28)
	metadata, err := agentTestMetadata(agentTestArtifactConfig{
		expectedCommit: commit,
		workflowCommit: commit,
		baseURL:        "https://artifacts.example.com/agent-tests",
	}, "3.2.1")
	if err != nil {
		t.Fatal(err)
	}
	if metadata.Version != "3.2.1-test.sha001234567890" {
		t.Fatalf("commit prefix must be an alphanumeric SemVer identifier: %q", metadata.Version)
	}
}

func TestAgentTestArtifactURLRejectsUnreviewableLocations(t *testing.T) {
	for _, value := range []string{
		"http://artifacts.example.com/tests", "https://user:secret@artifacts.example.com/tests",
		"https://artifacts.example.com:443/tests", "https://artifacts.example.com/tests?token=value",
		"https://artifacts.example.com/tests?", "https://artifacts.example.com/tests#fragment",
		"https://192.0.2.1/tests", "https://[2001:db8::1]/tests", "https://localhost/tests",
		"https://host.local/tests", "https://host.internal/tests", "https://host.localhost/tests",
		"https://artifacts.example.com/../tests", "https://artifacts.example.com/%2e%2e/tests",
		"https://artifacts.example.com//tests", "https://artifacts.example.com/",
		"https://artifacts..example.com/tests", "https://-artifacts.example.com/tests",
	} {
		if _, err := validateAgentTestBaseURL(value); !errors.Is(err, errAgentTestURL) {
			t.Errorf("URL accepted: %q (%v)", value, err)
		}
	}
}

func writeTestAgentArchive(t *testing.T, headers ...tar.Header) string {
	t.Helper()
	var contents bytes.Buffer
	compressed := gzip.NewWriter(&contents)
	archive := tar.NewWriter(compressed)
	for _, header := range headers {
		if err := archive.WriteHeader(&header); err != nil {
			t.Fatal(err)
		}
		if header.Typeflag == tar.TypeReg {
			if _, err := archive.Write(bytes.Repeat([]byte("x"), int(header.Size))); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "runtime.tar.gz")
	if err := os.WriteFile(path, contents.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func testAgentHeader() tar.Header {
	return tar.Header{Name: "./serviceradar-agent", Typeflag: tar.TypeReg, Size: 7, Mode: 0o755}
}

func TestAgentTestRuntimeArchiveShape(t *testing.T) {
	good := testAgentHeader()
	valid := writeTestAgentArchive(t, tar.Header{Name: "./", Typeflag: tar.TypeDir, Mode: 0o755}, good)
	destination := filepath.Join(t.TempDir(), "agent")
	if err := extractAgentTestRuntime(valid, destination); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(destination)
	if err != nil || string(contents) != "xxxxxxx" {
		t.Fatalf("extracted bytes: %q, %v", contents, err)
	}
	for name, headers := range map[string][]tar.Header{
		"empty": {}, "duplicate": {good, good},
		"other file":       {good, {Name: "other", Typeflag: tar.TypeReg, Mode: 0o755, Size: 1}},
		"symlink":          {{Name: "serviceradar-agent", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd"}},
		"traversal":        {{Name: "../serviceradar-agent", Typeflag: tar.TypeReg, Mode: 0o755, Size: 1}},
		"non executable":   {{Name: "serviceradar-agent", Typeflag: tar.TypeReg, Mode: 0o644, Size: 1}},
		"nested directory": {{Name: "nested/", Typeflag: tar.TypeDir, Mode: 0o755}, good},
	} {
		t.Run(name, func(t *testing.T) {
			path := writeTestAgentArchive(t, headers...)
			if err := extractAgentTestRuntime(path, filepath.Join(t.TempDir(), "agent")); !errors.Is(err, errAgentTestArchive) {
				t.Fatalf("invalid archive accepted: %v", err)
			}
		})
	}
}

func TestAgentTestArtifactSignsCanonicalManifestAndCopiesExactArchive(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(releasePrivateKeyEnv, base64.StdEncoding.EncodeToString(private))
	metadata := testAgentMetadata(t)
	archive := writeTestAgentArchive(t, testAgentHeader())
	output := filepath.Join(t.TempDir(), "output")
	if err := prepareAgentTestArtifact(metadata, archive, output, public, func(string) (string, error) { return metadata.Version, nil }); err != nil {
		t.Fatal(err)
	}
	manifestBytes, err := os.ReadFile(filepath.Join(output, defaultAgentManifestAssetName))
	if err != nil {
		t.Fatal(err)
	}
	signature, err := os.ReadFile(filepath.Join(output, defaultAgentManifestSigAssetName))
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodeReleaseSigningValue(string(signature))
	if err != nil || !ed25519.Verify(public, manifestBytes, decoded) {
		t.Fatal("signature does not verify")
	}
	var manifest agentReleaseManifest
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		t.Fatal(err)
	}
	digest, err := fileSHA256(archive)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Version != metadata.Version || len(manifest.Artifacts) != 1 || manifest.Artifacts[0].SHA256 != digest || manifest.Artifacts[0].URL != metadata.ArtifactURL || manifest.Artifacts[0].Entrypoint != "serviceradar-agent" {
		t.Fatalf("wrong manifest: %+v", manifest)
	}
	payload, err := manifestCanonicalPayload(manifest)
	if err != nil {
		t.Fatal(err)
	}
	canonical, err := marshalCanonicalJSON(payload)
	if err != nil || !bytes.Equal(canonical, manifestBytes) {
		t.Fatal("manifest is not canonical")
	}
	copyDigest, err := fileSHA256(filepath.Join(output, metadata.ArtifactName))
	if err != nil || copyDigest != digest {
		t.Fatal("archive copy differs")
	}
	entries, err := os.ReadDir(output)
	if err != nil || len(entries) != 4 {
		t.Fatalf("unexpected output files: %v, %v", entries, err)
	}
}

func TestAgentTestArtifactFailureExposesNoOutput(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	otherPublic, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(releasePrivateKeyEnv, base64.StdEncoding.EncodeToString(private))
	metadata := testAgentMetadata(t)
	archive := writeTestAgentArchive(t, testAgentHeader())
	for _, tc := range []struct {
		name, version string
		key           ed25519.PublicKey
		want          error
	}{
		{"version mismatch", "3.2.1", public, errAgentTestBinaryVersion},
		{"wrong trust root", metadata.Version, otherPublic, errAgentTestSigningKey},
	} {
		t.Run(tc.name, func(t *testing.T) {
			parent := t.TempDir()
			output := filepath.Join(parent, "output")
			err := prepareAgentTestArtifact(metadata, archive, output, tc.key, func(string) (string, error) { return tc.version, nil })
			if !errors.Is(err, tc.want) {
				t.Fatalf("got %v want %v", err, tc.want)
			}
			entries, err := os.ReadDir(parent)
			if err != nil || len(entries) != 0 {
				t.Fatalf("failed signing exposed files: %v, %v", entries, err)
			}
		})
	}
}

func TestAgentTestVersionProbeFailureExposesNoOutput(t *testing.T) {
	metadata := testAgentMetadata(t)
	archive := writeTestAgentArchive(t, testAgentHeader())
	parent := t.TempDir()
	err := prepareAgentTestArtifact(metadata, archive, filepath.Join(parent, "output"), nil,
		func(string) (string, error) { return "", os.ErrPermission })
	if !errors.Is(err, os.ErrPermission) {
		t.Fatalf("probe error was not preserved: %v", err)
	}
	entries, err := os.ReadDir(parent)
	if err != nil || len(entries) != 0 {
		t.Fatalf("failed probe exposed files: %v, %v", entries, err)
	}
	if _, err := agentTestBinaryVersion(filepath.Join(parent, "missing")); err == nil {
		t.Fatal("missing executable was accepted")
	}
}

func TestAgentTestArchiveRejectsOversizeBeforeExtraction(t *testing.T) {
	archive, err := os.CreateTemp(t.TempDir(), "oversize-")
	if err != nil {
		t.Fatal(err)
	}
	if err := archive.Truncate(agentTestArchiveLimit + 1); err != nil {
		t.Fatal(err)
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := extractAgentTestRuntime(archive.Name(), filepath.Join(t.TempDir(), "agent")); !errors.Is(err, errAgentTestArchive) {
		t.Fatalf("oversize archive not rejected: %v", err)
	}
}

func TestAgentTestVersionProbeDoesNotInheritSigningEnvironment(t *testing.T) {
	t.Setenv("AGENT_TEST_SECRET", "synthetic-sensitive-value")
	t.Setenv(releasePrivateKeyEnv, "synthetic-sensitive-key")
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	version, err := agentTestBinaryVersion(path)
	if err != nil || version != "3.2.1-test.synthetic" {
		t.Fatalf("version probe: %q, %v", version, err)
	}
}
