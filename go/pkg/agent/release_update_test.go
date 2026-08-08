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

const (
	testReleaseCommandID                     = "00000000-0000-4000-8000-000000000123"
	testReleaseHelperReadyReasonNotValidated = "live_auth_media_demo_not_validated"
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

func TestStageAgentReleaseUsesEnvironmentVerificationKeyFallback(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("ed25519.GenerateKey() error = %v", err)
	}

	originalKey := ReleaseSigningPublicKey
	ReleaseSigningPublicKey = ""
	t.Setenv("SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY", base64.StdEncoding.EncodeToString(publicKey))
	t.Cleanup(func() {
		ReleaseSigningPublicKey = originalKey
	})

	payload := signedReleasePayloadWithSigner(t, binaryData, releaseArtifactPayload{
		URL:    server.URL + "/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	}, privateKey)

	_, err = stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if err != nil {
		t.Fatalf("expected env verification key fallback to verify release, got %v", err)
	}
}

func TestStageAgentReleaseEmbeddedVerificationKeyWinsOverEnvironment(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("ed25519.GenerateKey() error = %v", err)
	}

	otherPublicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("ed25519.GenerateKey() error = %v", err)
	}

	t.Setenv("SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY", base64.StdEncoding.EncodeToString(otherPublicKey))
	originalKey := ReleaseSigningPublicKey
	ReleaseSigningPublicKey = base64.StdEncoding.EncodeToString(publicKey)
	t.Cleanup(func() {
		ReleaseSigningPublicKey = originalKey
	})

	payload := signedReleasePayloadWithSigner(t, binaryData, releaseArtifactPayload{
		URL:    server.URL + "/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	}, privateKey)

	_, err = stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if err != nil {
		t.Fatalf("expected embedded verification key to win over env override, got %v", err)
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

func TestStageAgentReleaseRejectsHelperInstallWithoutRDPCapability(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:    server.URL + "/serviceradar-agent",
		SHA256: digestHex(binaryData),
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
	})
	payload.HelperInstall = &releaseHelperInstall{
		Enabled:    true,
		Capability: releaseCapabilityRemoteAccessRDP,
	}

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if !errors.Is(err, errReleaseHelperCapabilityMissing) {
		t.Fatalf("expected errReleaseHelperCapabilityMissing, got %v", err)
	}
}

func TestStageAgentReleaseRejectsHelperInstallForUnsupportedCapability(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	payload := signedReleasePayload(t, binaryData, releaseArtifactPayload{
		URL:          server.URL + "/serviceradar-agent",
		SHA256:       digestHex(binaryData),
		OS:           runtime.GOOS,
		Arch:         runtime.GOARCH,
		Capabilities: []string{"agent"},
	})
	payload.HelperInstall = &releaseHelperInstall{
		Enabled:    true,
		Capability: "agent",
	}

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if !errors.Is(err, errReleaseHelperCapabilityMissing) {
		t.Fatalf("expected errReleaseHelperCapabilityMissing, got %v", err)
	}
}

func TestStageAgentReleaseAcceptsHelperInstallWithRDPCapability(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	artifact := validRDPReleaseArtifact(server.URL+"/serviceradar-agent-rdp", digestHex(binaryData))
	payload := signedReleasePayload(t, binaryData, artifact)
	payload.HelperInstall = &releaseHelperInstall{
		Enabled:                 true,
		Capability:              releaseCapabilityRemoteAccessRDP,
		HelperProtocolVersion:   artifact.HelperProtocolVersion,
		CompatibleAgentVersions: artifact.CompatibleAgentVersions,
		DeploymentRequirements:  artifact.DeploymentRequirements,
	}

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if err != nil {
		t.Fatalf("expected helper-capable artifact to stage, got %v", err)
	}
}

func TestStageAgentReleaseRejectsRDPHelperInstallMetadataMismatch(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	tests := []struct {
		name   string
		mutate func(*releaseHelperInstall)
	}{
		{
			name: "helper protocol differs",
			mutate: func(helper *releaseHelperInstall) {
				helper.HelperProtocolVersion = "other-helper-protocol"
			},
		},
		{
			name: "compatible agent range missing",
			mutate: func(helper *releaseHelperInstall) {
				helper.CompatibleAgentVersions = nil
			},
		},
		{
			name: "compatible agent range differs",
			mutate: func(helper *releaseHelperInstall) {
				helper.CompatibleAgentVersions[releaseCompatibleAgentMax] = "9.x"
			},
		},
		{
			name: "helper install path differs",
			mutate: func(helper *releaseHelperInstall) {
				helper.DeploymentRequirements[releaseRequirementInstallPath] = "/tmp/serviceradar-rdp-adapter"
			},
		},
		{
			name: "helper readiness flag differs",
			mutate: func(helper *releaseHelperInstall) {
				helper.DeploymentRequirements[releaseRequirementRequiresProbe] = false
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			artifact := validRDPReleaseArtifact(server.URL+"/serviceradar-agent-rdp", digestHex(binaryData))
			payload := signedReleasePayload(t, binaryData, artifact)
			payload.HelperInstall = &releaseHelperInstall{
				Enabled:                 true,
				Capability:              releaseCapabilityRemoteAccessRDP,
				HelperProtocolVersion:   artifact.HelperProtocolVersion,
				CompatibleAgentVersions: cloneStringMap(artifact.CompatibleAgentVersions),
				DeploymentRequirements:  cloneInterfaceMap(artifact.DeploymentRequirements),
			}
			tt.mutate(payload.HelperInstall)

			_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
				RuntimeRoot: t.TempDir(),
				HTTPClient:  server.Client(),
			})
			if !errors.Is(err, errReleaseHelperReadinessMissing) {
				t.Fatalf("expected errReleaseHelperReadinessMissing, got %v", err)
			}
		})
	}
}

func TestStageAgentReleaseRejectsRDPCapabilityWithoutReadinessMetadata(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	tests := []struct {
		name   string
		mutate func(*releaseArtifactPayload)
	}{
		{
			name: "missing helper protocol",
			mutate: func(artifact *releaseArtifactPayload) {
				artifact.HelperProtocolVersion = ""
			},
		},
		{
			name: "missing compatible agent range",
			mutate: func(artifact *releaseArtifactPayload) {
				artifact.CompatibleAgentVersions = nil
			},
		},
		{
			name: "missing helper binary",
			mutate: func(artifact *releaseArtifactPayload) {
				delete(artifact.DeploymentRequirements, releaseRequirementHelper)
			},
		},
		{
			name: "missing install path",
			mutate: func(artifact *releaseArtifactPayload) {
				delete(artifact.DeploymentRequirements, releaseRequirementInstallPath)
			},
		},
		{
			name: "missing readiness probe",
			mutate: func(artifact *releaseArtifactPayload) {
				delete(artifact.DeploymentRequirements, releaseRequirementHelperCapArg)
			},
		},
		{
			name: "readiness probe not required",
			mutate: func(artifact *releaseArtifactPayload) {
				artifact.DeploymentRequirements[releaseRequirementRequiresProbe] = false
			},
		},
		{
			name: "missing connector readiness",
			mutate: func(artifact *releaseArtifactPayload) {
				delete(artifact.DeploymentRequirements, releaseRequirementHelperReady)
			},
		},
		{
			name: "missing connector readiness reason for experimental artifact",
			mutate: func(artifact *releaseArtifactPayload) {
				artifact.DeploymentRequirements[releaseRequirementHelperReady] = false
				artifact.DeploymentRequirements[releaseRequirementReleasePhase] = releaseReleasePhaseExperimental
			},
		},
		{
			name: "connector readiness reason present for ready artifact",
			mutate: func(artifact *releaseArtifactPayload) {
				artifact.DeploymentRequirements[releaseRequirementHelperReadyReason] = testReleaseHelperReadyReasonNotValidated
			},
		},
		{
			name: "connector not ready without experimental phase",
			mutate: func(artifact *releaseArtifactPayload) {
				artifact.DeploymentRequirements[releaseRequirementHelperReady] = false
				artifact.DeploymentRequirements[releaseRequirementHelperReadyReason] = testReleaseHelperReadyReasonNotValidated
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			artifact := validRDPReleaseArtifact(server.URL+"/serviceradar-agent-rdp", digestHex(binaryData))
			tt.mutate(&artifact)
			payload := signedReleasePayload(t, binaryData, artifact)
			payload.HelperInstall = &releaseHelperInstall{
				Enabled:    true,
				Capability: releaseCapabilityRemoteAccessRDP,
			}

			_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
				RuntimeRoot: t.TempDir(),
				HTTPClient:  server.Client(),
			})
			if !errors.Is(err, errReleaseHelperReadinessMissing) {
				t.Fatalf("expected errReleaseHelperReadinessMissing, got %v", err)
			}
		})
	}
}

func TestStageAgentReleaseRejectsHelperInstallWhenRDPConnectorNotReady(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	artifact := validRDPReleaseArtifact(server.URL+"/serviceradar-agent-rdp", digestHex(binaryData))
	artifact.DeploymentRequirements[releaseRequirementHelperReady] = false
	artifact.DeploymentRequirements[releaseRequirementReleasePhase] = releaseReleasePhaseExperimental
	artifact.DeploymentRequirements[releaseRequirementHelperReadyReason] = testReleaseHelperReadyReasonNotValidated
	payload := signedReleasePayload(t, binaryData, artifact)
	payload.HelperInstall = &releaseHelperInstall{
		Enabled:    true,
		Capability: releaseCapabilityRemoteAccessRDP,
	}

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if !errors.Is(err, errReleaseHelperConnectorNotReady) {
		t.Fatalf("expected errReleaseHelperConnectorNotReady, got %v", err)
	}
}

func TestStageAgentReleaseAcceptsRDPArtifactMarkedConnectorNotReadyWithoutHelperInstall(t *testing.T) {
	binaryData := []byte("binary")
	server := newArtifactServer(t, binaryData)
	defer server.Close()

	artifact := validRDPReleaseArtifact(server.URL+"/serviceradar-agent-rdp", digestHex(binaryData))
	artifact.DeploymentRequirements[releaseRequirementHelperReady] = false
	artifact.DeploymentRequirements[releaseRequirementReleasePhase] = releaseReleasePhaseExperimental
	artifact.DeploymentRequirements[releaseRequirementHelperReadyReason] = testReleaseHelperReadyReasonNotValidated
	payload := signedReleasePayload(t, binaryData, artifact)

	_, err := stageAgentRelease(context.Background(), payload, releaseStageConfig{
		RuntimeRoot: t.TempDir(),
		HTTPClient:  server.Client(),
	})
	if err != nil {
		t.Fatalf("expected connector-not-ready metadata to be accepted without helper install, got %v", err)
	}
}

func validRDPReleaseArtifact(url, digest string) releaseArtifactPayload {
	return releaseArtifactPayload{
		URL:                   url,
		SHA256:                digest,
		OS:                    runtime.GOOS,
		Arch:                  runtime.GOARCH,
		Capabilities:          []string{"agent", releaseCapabilityRemoteAccessRDP},
		HelperProtocolVersion: "srdp-helper-v1",
		CompatibleAgentVersions: map[string]string{
			"min": "1.1.0",
			"max": "1.2.x",
		},
		DeploymentRequirements: map[string]interface{}{
			releaseRequirementHelper:        releaseRDPHelperBinary,
			releaseRequirementInstallPath:   releaseRDPHelperInstallPath,
			releaseRequirementHelperCapArg:  releaseRDPHelperReadinessProbe,
			releaseRequirementRequiresProbe: true,
			releaseRequirementHelperReady:   true,
		},
	}
}

func cloneStringMap(values map[string]string) map[string]string {
	if values == nil {
		return nil
	}
	cloned := make(map[string]string, len(values))
	for key, value := range values {
		cloned[key] = value
	}

	return cloned
}

func cloneInterfaceMap(values map[string]interface{}) map[string]interface{} {
	if values == nil {
		return nil
	}
	cloned := make(map[string]interface{}, len(values))
	for key, value := range values {
		cloned[key] = value
	}

	return cloned
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
	// A redirect rejection is not a status error, so isRetryableReleaseDownloadError
	// classifies it transient and downloadReleaseArtifact burns the full 1s+2s+4s
	// backoff before returning it. Without this the test costs 7s.
	shrinkReleaseDownloadBackoff(t)

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
	shrinkReleaseDownloadBackoff(t)

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
	shrinkReleaseDownloadBackoff(t)

	binaryData := []byte("gateway-binary")
	artifactServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "artifact", time.Unix(0, 0), bytes.NewReader(binaryData))
	}))
	defer artifactServer.Close()

	gatewayServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("X-ServiceRadar-Release-Target-ID"); got != "target-123" {
			t.Fatalf("target header = %q, want %q", got, "target-123")
		}
		if got := r.Header.Get("X-ServiceRadar-Release-Command-ID"); got != testReleaseCommandID {
			t.Fatalf("command header = %q, want %q", got, testReleaseCommandID)
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
		CommandID:   testReleaseCommandID,
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
		if got := r.Header.Get("X-ServiceRadar-Release-Command-ID"); got != testReleaseCommandID {
			t.Fatalf("command header = %q, want %q", got, testReleaseCommandID)
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
		CommandID:   testReleaseCommandID,
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
	originalKey := ReleaseSigningPublicKey
	ReleaseSigningPublicKey = base64.StdEncoding.EncodeToString(publicKey)
	t.Cleanup(func() {
		ReleaseSigningPublicKey = originalKey
	})

	return signedReleasePayloadWithSigner(t, artifactData, artifact, privateKey)
}

func signedReleasePayloadWithSigner(t *testing.T, artifactData []byte, artifact releaseArtifactPayload, privateKey ed25519.PrivateKey) releaseUpdatePayload {
	t.Helper()

	manifestArtifact := map[string]interface{}{
		"url":        artifact.URL,
		"sha256":     digestHex(artifactData),
		"os":         artifact.OS,
		"arch":       artifact.Arch,
		"format":     artifact.Format,
		"entrypoint": artifact.Entrypoint,
	}
	if len(artifact.Capabilities) > 0 {
		manifestArtifact["capabilities"] = artifact.Capabilities
	}
	if artifact.HelperProtocolVersion != "" {
		manifestArtifact["helper_protocol_version"] = artifact.HelperProtocolVersion
	}
	if len(artifact.CompatibleAgentVersions) > 0 {
		manifestArtifact["compatible_agent_versions"] = artifact.CompatibleAgentVersions
	}
	if len(artifact.DeploymentRequirements) > 0 {
		manifestArtifact["deployment_requirements"] = artifact.DeploymentRequirements
	}

	manifest := map[string]interface{}{
		"version": "1.1.0",
		"artifacts": []interface{}{
			manifestArtifact,
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

func shrinkReleaseDownloadBackoff(t *testing.T) {
	t.Helper()

	origInit := releaseDownloadInitialBackoff
	origMax := releaseDownloadMaxBackoff
	releaseDownloadInitialBackoff = time.Millisecond
	releaseDownloadMaxBackoff = 2 * time.Millisecond
	t.Cleanup(func() {
		releaseDownloadInitialBackoff = origInit
		releaseDownloadMaxBackoff = origMax
	})
}

func releaseDownloadTestPayload(t *testing.T, url string, data []byte) releaseUpdatePayload {
	t.Helper()

	return releaseUpdatePayload{
		Artifact: releaseArtifactPayload{
			URL:    url,
			SHA256: digestHex(data),
			OS:     runtime.GOOS,
			Arch:   runtime.GOARCH,
		},
	}
}

func TestDownloadReleaseArtifactRetriesTransientStatusThenSucceeds(t *testing.T) {
	shrinkReleaseDownloadBackoff(t)

	data := []byte("retryable-artifact")
	var attempts int
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts < 3 {
			// 409 mirrors the gateway's "artifact not ready yet" response.
			http.Error(w, "not ready", http.StatusConflict)
			return
		}
		http.ServeContent(w, r, "artifact", time.Unix(0, 0), bytes.NewReader(data))
	}))
	defer server.Close()

	got, err := downloadReleaseArtifact(
		context.Background(),
		releaseDownloadTestPayload(t, server.URL, data),
		releaseStageConfig{HTTPClient: server.Client()},
	)
	if err != nil {
		t.Fatalf("downloadReleaseArtifact() error = %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Fatalf("downloadReleaseArtifact() = %q, want %q", got, data)
	}
	if attempts != 3 {
		t.Fatalf("attempts = %d, want 3", attempts)
	}
}

func TestDownloadReleaseArtifactDoesNotRetryTerminalStatus(t *testing.T) {
	shrinkReleaseDownloadBackoff(t)

	var attempts int
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts++
		http.Error(w, "forbidden", http.StatusForbidden)
	}))
	defer server.Close()

	data := []byte("terminal")
	_, err := downloadReleaseArtifact(
		context.Background(),
		releaseDownloadTestPayload(t, server.URL, data),
		releaseStageConfig{HTTPClient: server.Client()},
	)
	if err == nil {
		t.Fatal("expected terminal 403 download to fail")
	}
	if !errors.Is(err, errDownloadFailed) {
		t.Fatalf("error = %v, want errDownloadFailed", err)
	}
	if attempts != 1 {
		t.Fatalf("attempts = %d, want 1 (terminal status must not retry)", attempts)
	}
}

func TestDownloadReleaseArtifactExhaustsRetriesThenFails(t *testing.T) {
	shrinkReleaseDownloadBackoff(t)

	var attempts int
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts++
		http.Error(w, "not ready", http.StatusConflict)
	}))
	defer server.Close()

	data := []byte("never-ready")
	_, err := downloadReleaseArtifact(
		context.Background(),
		releaseDownloadTestPayload(t, server.URL, data),
		releaseStageConfig{HTTPClient: server.Client()},
	)
	if err == nil {
		t.Fatal("expected exhausted retries to fail")
	}
	if attempts != releaseDownloadMaxAttempts {
		t.Fatalf("attempts = %d, want %d", attempts, releaseDownloadMaxAttempts)
	}
}
