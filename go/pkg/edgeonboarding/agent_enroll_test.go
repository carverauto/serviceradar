package edgeonboarding

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestMergeEnvOverridesPreservesExistingEntries(t *testing.T) {
	t.Parallel()

	existing := []byte("# existing config\nOTHER_SETTING=keep\n")
	updates := map[string]string{
		"SAFE_SETTING": "new-value",
	}

	merged := mergeEnvOverrides(existing, updates)
	text := string(merged)

	assert.Contains(t, text, "# existing config\n")
	assert.Contains(t, text, "OTHER_SETTING=keep\n")
	assert.Contains(t, text, "SAFE_SETTING=new-value\n")
}

func TestMergeEnvOverridesAddsSafeSettingToEmptyFile(t *testing.T) {
	t.Parallel()

	merged := mergeEnvOverrides(nil, map[string]string{
		"SAFE_SETTING": "value",
	})

	assert.Equal(t, "SAFE_SETTING=value\n", string(merged))
}

func TestExtractBundleReadsOptionalOverridesFile(t *testing.T) {
	t.Parallel()

	payload, err := extractBundle(testAgentBundle(t, "SAFE_SETTING=test-key\n"))
	require.NoError(t, err)

	assert.Equal(t, "SAFE_SETTING=test-key\n", string(payload.EnvOverrides))
}

func TestExtractBundleReadsOptionalNATSCredsFile(t *testing.T) {
	t.Parallel()

	credsContent := "-----BEGIN NATS USER JWT-----\ntoken\n------END NATS USER JWT------\n"

	payload, err := extractBundle(
		testAgentBundleWith(t, withNATSCreds(credsContent)),
	)
	require.NoError(t, err)

	assert.Equal(t, credsContent, string(payload.NATSCreds))
}

func TestExtractBundleNATSCredsIsOptional(t *testing.T) {
	t.Parallel()

	payload, err := extractBundle(testAgentBundle(t, ""))
	require.NoError(t, err)
	assert.Empty(t, payload.NATSCreds, "bundle without nats.creds must still parse cleanly")
}

func TestResolveAgentNATSCredsPathFallsBackToDefault(t *testing.T) {
	t.Parallel()

	assert.Equal(t, defaultAgentNATSCredsPath, resolveAgentNATSCredsPath(""))
	assert.Equal(t, defaultAgentNATSCredsPath, resolveAgentNATSCredsPath("   "))
	assert.Equal(t, "/var/run/sr/nats.creds", resolveAgentNATSCredsPath("/var/run/sr/nats.creds"))
}

func TestExtractEnvOverridesRejectsProtectedKeys(t *testing.T) {
	t.Parallel()

	updates := extractEnvOverrides([]byte(strings.Join([]string{
		"SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY=test-key",
		"SERVICERADAR_AGENT_UPDATER=/tmp/evil",
		"SERVICERADAR_AGENT_RUNTIME_ROOT=/tmp/root",
		"SERVICERADAR_AGENT_SEED_BINARY=/tmp/seed",
		"SAFE_SETTING=allowed",
	}, "\n")))

	assert.Equal(t, map[string]string{"SAFE_SETTING": "allowed"}, updates)
}

func TestNormalizeCoreURLRequiresHTTPS(t *testing.T) {
	t.Parallel()

	normalized, err := normalizeCoreURL("demo.serviceradar.cloud")
	require.NoError(t, err)
	assert.Equal(t, "https://demo.serviceradar.cloud", normalized)

	_, err = normalizeCoreURL("http://demo.serviceradar.cloud")
	require.ErrorIs(t, err, ErrCoreAPIURLMustUseHTTPS)
}

func TestParseCollectorTokenRequiresHTTPS(t *testing.T) {
	token := signedCollectorToken(t, "http://demo.serviceradar.cloud", "pkg-1", "secret")
	_, err := parseCollectorToken(token, "")
	require.ErrorIs(t, err, ErrCoreAPIURLMustUseHTTPS)
}

func TestParseCollectorTokenRejectsUnsignedFormats(t *testing.T) {
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	_, err := parseCollectorToken("collectorpkg-v1:abc", "https://demo.serviceradar.cloud")
	require.ErrorIs(t, err, ErrCollectorTokenInvalid)

	legacyRaw := base64.RawURLEncoding.EncodeToString([]byte(`{"u":"https://demo","p":"pkg-1","t":"secret"}`))
	_, err = parseCollectorToken(legacyRaw, "https://demo.serviceradar.cloud")
	require.ErrorIs(t, err, ErrCollectorTokenInvalid)
}

func TestNewBundleDownloadRequestUsesPostAndHeader(t *testing.T) {
	t.Parallel()

	req, err := newBundleDownloadRequest(
		context.Background(),
		"https://demo.serviceradar.cloud/api/edge-packages/pkg-1/bundle",
		"token-123",
	)
	require.NoError(t, err)

	assert.Equal(t, http.MethodPost, req.Method)
	assert.Equal(
		t,
		"https://demo.serviceradar.cloud/api/edge-packages/pkg-1/bundle",
		req.URL.String(),
	)
	assert.Equal(t, "token-123", req.Header.Get(downloadTokenHeader))
}

func testAgentBundle(t *testing.T, overrides string) *bytes.Reader {
	t.Helper()

	var opts []agentBundleOpt
	if overrides != "" {
		opts = append(opts, withOverrides(overrides))
	}

	return testAgentBundleWith(t, opts...)
}

// agentBundleOpt customizes the test tarball produced by
// testAgentBundleWith. Centralizing this avoids stamping out a parallel
// helper for each new optional bundle file.
type agentBundleOpt func(*agentBundleSpec)

type agentBundleSpec struct {
	overrides string
	natsCreds string
}

func withOverrides(content string) agentBundleOpt {
	return func(s *agentBundleSpec) { s.overrides = content }
}

func withNATSCreds(content string) agentBundleOpt {
	return func(s *agentBundleSpec) { s.natsCreds = content }
}

func testAgentBundleWith(t *testing.T, options ...agentBundleOpt) *bytes.Reader {
	t.Helper()

	spec := &agentBundleSpec{}
	for _, opt := range options {
		opt(spec)
	}

	var archive bytes.Buffer
	gzw := gzip.NewWriter(&archive)
	tw := tar.NewWriter(gzw)

	writeBundleFile := func(name string, body []byte) {
		t.Helper()

		hdr := &tar.Header{
			Name: name,
			Size: int64(len(body)),
			Mode: 0o600,
		}
		require.NoError(t, tw.WriteHeader(hdr))
		_, err := tw.Write(body)
		require.NoError(t, err)
	}

	writeBundleFile("edge-package-test/config/config.json", []byte(`{"agent_id":"agent-1"}`))
	writeBundleFile("edge-package-test/certs/component.pem", []byte("cert"))
	writeBundleFile("edge-package-test/certs/component-key.pem", []byte("key"))
	writeBundleFile("edge-package-test/certs/ca-chain.pem", []byte("ca"))

	if spec.overrides != "" {
		writeBundleFile(
			"edge-package-test/config/agent-env-overrides.env",
			[]byte(spec.overrides),
		)
	}

	if spec.natsCreds != "" {
		writeBundleFile("edge-package-test/creds/nats.creds", []byte(spec.natsCreds))
	}

	require.NoError(t, tw.Close())
	require.NoError(t, gzw.Close())

	return bytes.NewReader(archive.Bytes())
}

func signedCollectorToken(t *testing.T, baseURL, packageID, secret string) string {
	t.Helper()
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	seed, err := base64.StdEncoding.DecodeString(testOnboardingTokenPrivateKey)
	require.NoError(t, err)

	privateKey := ed25519.NewKeyFromSeed(seed)
	payload := map[string]any{
		"u": baseURL,
		"p": packageID,
		"t": secret,
	}

	data, err := json.Marshal(payload)
	require.NoError(t, err)

	signature := ed25519.Sign(privateKey, data)
	return collectorTokenV2Prefix +
		base64.RawURLEncoding.EncodeToString(data) +
		onboardingTokenSignatureSep +
		base64.RawURLEncoding.EncodeToString(signature)
}
