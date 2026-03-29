package edgeonboarding

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestMergeEnvOverridesPreservesExistingEntries(t *testing.T) {
	t.Parallel()

	existing := []byte("# existing config\nOTHER_SETTING=keep\nSERVICERADAR_AGENT_RELEASE_PUBLIC_KEY=old\n")
	updates := map[string]string{
		releasePublicKeyEnv: "new-public-key",
	}

	merged := mergeEnvOverrides(existing, updates)
	text := string(merged)

	assert.Contains(t, text, "# existing config\n")
	assert.Contains(t, text, "OTHER_SETTING=keep\n")
	assert.Contains(t, text, "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY=new-public-key\n")
	assert.NotContains(t, text, "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY=old\n")
}

func TestMergeEnvOverridesAddsReleaseKeyToEmptyFile(t *testing.T) {
	t.Parallel()

	merged := mergeEnvOverrides(nil, map[string]string{
		releasePublicKeyEnv: "dLbXN6ouezVOgWJhOPoGTm1moz8MuxDcPmX5RdjM0Ns=",
	})

	assert.Equal(
		t,
		"SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY=dLbXN6ouezVOgWJhOPoGTm1moz8MuxDcPmX5RdjM0Ns=\n",
		string(merged),
	)
}

func TestExtractBundleReadsOptionalOverridesFile(t *testing.T) {
	t.Parallel()

	payload, err := extractBundle(testAgentBundle(t, "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY=test-key\n"))
	require.NoError(t, err)

	assert.Equal(
		t,
		"SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY=test-key\n",
		string(payload.EnvOverrides),
	)
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

func testAgentBundle(t *testing.T, overrides string) *bytes.Reader {
	t.Helper()

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

	if overrides != "" {
		writeBundleFile("edge-package-test/config/agent-env-overrides.env", []byte(overrides))
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
