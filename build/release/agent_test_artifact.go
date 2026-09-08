package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const agentTestPublicKeyRunfile = "go/pkg/agent/release_signing_key.txt"

// Match ReleaseArtifactMirror's compressed download limit. Extraction has its own cap.
const agentTestArchiveLimit = 256 * 1024 * 1024
const agentTestExecutableLimit = 512 * 1024 * 1024

var (
	errAgentTestCommit         = errors.New("expected commit must be 40 lowercase hexadecimal characters and match the workflow commit")
	errAgentTestVersion        = errors.New("base version must be a stable semantic version")
	errAgentTestURL            = errors.New("artifact base must be an HTTPS DNS origin and safe directory path without credentials, port, query, or fragment")
	errAgentTestArchive        = errors.New("runtime archive must contain exactly one regular executable named serviceradar-agent")
	errAgentTestBinaryVersion  = errors.New("runtime binary version does not match the derived prerelease")
	errAgentTestSigningKey     = errors.New("manifest signing key does not match the committed agent trust root")
	errAgentTestOutput         = errors.New("artifact output directory must not already exist")
	errAgentTestArguments      = errors.New("unexpected positional arguments")
	errAgentTestMetadataOutput = errors.New("--github-output is required for metadata")
	errAgentTestArtifactOutput = errors.New("--output-dir is required for artifacts")
)

type agentTestArtifactConfig struct {
	expectedCommit string
	workflowCommit string
	baseURL        string
	outputDir      string
	githubOutput   string
}

type agentTestArtifactMetadata struct {
	Commit       string `json:"commit"`
	Version      string `json:"version"`
	ArtifactURL  string `json:"artifact_url"`
	ArtifactName string `json:"artifact_name"`
	SHA256       string `json:"sha256,omitempty"`
}

func runAgentTestArtifactCommand(command string, args []string) error {
	config, err := parseAgentTestArtifactConfig(args)
	if err != nil {
		return err
	}
	resolver, err := newRunfileResolver()
	if err != nil {
		return err
	}
	versionPath, err := resolver.resolve("VERSION")
	if err != nil {
		return err
	}
	baseVersion, err := os.ReadFile(versionPath)
	if err != nil {
		return err
	}
	metadata, err := agentTestMetadata(config, strings.TrimSpace(string(baseVersion)))
	if err != nil {
		return err
	}
	if command == "agent-test-metadata" {
		return writeAgentTestMetadata(metadata, config.githubOutput)
	}
	archivePath, err := resolver.resolve(defaultAgentRuntimeRunfile)
	if err != nil {
		return err
	}
	publicKeyPath, err := resolver.resolve(agentTestPublicKeyRunfile)
	if err != nil {
		return err
	}
	publicKey, err := readAgentTestPublicKey(publicKeyPath)
	if err != nil {
		return err
	}
	return prepareAgentTestArtifact(metadata, archivePath, config.outputDir, publicKey, agentTestBinaryVersion)
}

func parseAgentTestArtifactConfig(args []string) (agentTestArtifactConfig, error) {
	var config agentTestArtifactConfig
	flags := flag.NewFlagSet("agent-test-artifact", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&config.expectedCommit, "expected-commit", "", "reviewed source commit")
	flags.StringVar(&config.workflowCommit, "workflow-commit", "", "workflow source commit")
	flags.StringVar(&config.baseURL, "artifact-base-url", "", "protected environment artifact base")
	flags.StringVar(&config.outputDir, "output-dir", "", "new output directory")
	flags.StringVar(&config.githubOutput, "github-output", "", "GitHub Actions output file")
	if err := flags.Parse(args); err != nil {
		return config, err
	}
	if flags.NArg() != 0 {
		return config, errAgentTestArguments
	}
	return config, nil
}

func agentTestMetadata(config agentTestArtifactConfig, baseVersion string) (agentTestArtifactMetadata, error) {
	var metadata agentTestArtifactMetadata
	if !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(config.expectedCommit) || config.expectedCommit != config.workflowCommit {
		return metadata, errAgentTestCommit
	}
	if !regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`).MatchString(baseVersion) {
		return metadata, errAgentTestVersion
	}
	base, err := validateAgentTestBaseURL(config.baseURL)
	if err != nil {
		return metadata, err
	}
	metadata.Commit = config.expectedCommit
	metadata.Version = baseVersion + "-test." + config.expectedCommit[:12]
	metadata.ArtifactName = "serviceradar-agent_" + metadata.Version + "_linux_amd64.tar.gz"
	metadata.ArtifactURL = base + "/" + metadata.Commit + "/" + metadata.ArtifactName
	return metadata, nil
}

func validateAgentTestBaseURL(value string) (string, error) {
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Port() != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.Opaque != "" || u.RawPath != "" {
		return "", errAgentTestURL
	}
	host := u.Hostname()
	if host != strings.ToLower(host) || net.ParseIP(host) != nil || len(host) > 253 || !strings.Contains(host, ".") {
		return "", errAgentTestURL
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) > 63 || !regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`).MatchString(label) {
			return "", errAgentTestURL
		}
	}
	for _, suffix := range []string{".localhost", ".local", ".internal"} {
		if strings.HasSuffix(host, suffix) {
			return "", errAgentTestURL
		}
	}
	path := strings.TrimSuffix(u.Path, "/")
	if !regexp.MustCompile(`^(/[a-zA-Z0-9_-]+)+$`).MatchString(path) {
		return "", errAgentTestURL
	}
	u.Path = path
	return u.String(), nil
}

func writeAgentTestMetadata(metadata agentTestArtifactMetadata, outputPath string) error {
	if outputPath == "" {
		return errAgentTestMetadataOutput
	}
	file, err := os.OpenFile(outputPath, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	_, writeErr := fmt.Fprintf(file, "version=%s\nartifact_name=%s\nartifact_url=%s\n", metadata.Version, metadata.ArtifactName, metadata.ArtifactURL)
	return errors.Join(writeErr, file.Close())
}

func readAgentTestPublicKey(path string) (ed25519.PublicKey, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(string(contents), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, decodeErr := decodeReleaseSigningValue(line)
		if decodeErr != nil || len(key) != ed25519.PublicKeySize {
			return nil, errAgentTestSigningKey
		}
		return ed25519.PublicKey(key), nil
	}
	return nil, errAgentTestSigningKey
}

func prepareAgentTestArtifact(metadata agentTestArtifactMetadata, archivePath, outputDir string, publicKey ed25519.PublicKey, readVersion func(string) (string, error)) error {
	if outputDir == "" {
		return errAgentTestArtifactOutput
	}
	if _, err := os.Lstat(outputDir); !os.IsNotExist(err) {
		return errAgentTestOutput
	}
	staging, err := os.MkdirTemp(filepath.Dir(outputDir), ".agent-test-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(staging) }()
	binaryPath := filepath.Join(staging, "serviceradar-agent")
	if err := extractAgentTestRuntime(archivePath, binaryPath); err != nil {
		return err
	}
	version, err := readVersion(binaryPath)
	if err != nil {
		return err
	}
	if version != metadata.Version {
		return errAgentTestBinaryVersion
	}
	if err := os.Remove(binaryPath); err != nil {
		return err
	}
	metadata.SHA256, err = fileSHA256(archivePath)
	if err != nil {
		return err
	}
	manifest := agentReleaseManifest{Version: metadata.Version, Artifacts: []agentReleaseManifestArtifact{baseAgentManifestArtifact(metadata.ArtifactURL, metadata.SHA256)}}
	payload, err := manifestCanonicalPayload(manifest)
	if err != nil {
		return err
	}
	canonical, err := marshalCanonicalJSON(payload)
	if err != nil {
		return err
	}
	signature, err := signManagedAgentManifest(canonical, false)
	if err != nil {
		return err
	}
	signatureBytes, err := decodeReleaseSigningValue(signature)
	if err != nil || !ed25519.Verify(publicKey, canonical, signatureBytes) {
		return errAgentTestSigningKey
	}
	provenance, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return err
	}
	for name, data := range map[string][]byte{
		defaultAgentManifestAssetName:    canonical,
		defaultAgentManifestSigAssetName: []byte(signature + "\n"),
		"provenance.json":                append(provenance, '\n'),
	} {
		if err := os.WriteFile(filepath.Join(staging, name), data, 0o644); err != nil {
			return err
		}
	}
	if err := copyAgentTestArchive(archivePath, filepath.Join(staging, metadata.ArtifactName)); err != nil {
		return err
	}
	return os.Rename(staging, outputDir)
}

func extractAgentTestRuntime(archivePath, binaryPath string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if info.Size() > agentTestArchiveLimit {
		return errAgentTestArchive
	}
	compressed, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer func() { _ = compressed.Close() }()
	archive := tar.NewReader(compressed)
	found := false
	for {
		header, err := archive.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if header.Typeflag == tar.TypeDir && (header.Name == "." || header.Name == "./" || header.Name == "/") {
			continue
		}
		if found || (header.Name != "serviceradar-agent" && header.Name != "./serviceradar-agent") || header.Typeflag != tar.TypeReg || header.Size <= 0 || header.Size > agentTestExecutableLimit || header.Mode&0o111 == 0 {
			return errAgentTestArchive
		}
		binary, err := os.OpenFile(binaryPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o700)
		if err != nil {
			return err
		}
		_, copyErr := io.CopyN(binary, archive, header.Size)
		if err := errors.Join(copyErr, binary.Close()); err != nil {
			return err
		}
		found = true
	}
	if !found {
		return errAgentTestArchive
	}
	return nil
}

func agentTestBinaryVersion(path string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, path, "--version")
	command.Env = []string{"PATH=/usr/bin:/bin"}
	command.Dir = filepath.Dir(path)
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return "", fmt.Errorf("runtime version probe failed: %w", err)
	}
	return strings.TrimSpace(output.String()), nil
}

func copyAgentTestArchive(source, destination string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer func() { _ = input.Close() }()
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, input)
	return errors.Join(copyErr, output.Close())
}
