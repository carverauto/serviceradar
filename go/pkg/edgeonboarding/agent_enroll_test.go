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
	"net/http/httptest"
	"os"
	"path/filepath"
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

func TestEnrollAgentRemovesLegacyNATSConfigAndBacksUpCreds(t *testing.T) {
	t.Setenv(onboardingTokenPrivateKeyEnv, testOnboardingTokenPrivateKey)
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	dir := t.TempDir()
	configPath := filepath.Join(dir, "agent.json")
	certDir := filepath.Join(dir, "certs")
	credsPath := filepath.Join(dir, "creds", "nats-agent.creds")

	require.NoError(t, os.MkdirAll(filepath.Dir(credsPath), 0o755))
	require.NoError(t, os.WriteFile(credsPath, []byte("existing-creds"), 0o600))
	require.NoError(t, os.WriteFile(configPath, []byte(`{
  "agent_id": "agent-1",
  "nats_url": "nats://existing:4222",
  "nats_creds_file": "`+credsPath+`"
}`), 0o644))

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/api/edge-packages/pkg-1/bundle", r.URL.Path)
		// The bundle endpoint verifies the full edgepkg envelope, so the CLI must send the
		// raw token (signature + bindings), not the bare inner download token.
		assert.True(t, strings.HasPrefix(r.Header.Get(downloadTokenHeader), tokenV3Prefix),
			"bundle request must carry the full edgepkg envelope, got %q", r.Header.Get(downloadTokenHeader))
		_, err := testAgentBundle(t, "").WriteTo(w)
		if !assert.NoError(t, err) {
			return
		}
	}))
	defer server.Close()

	token, err := EncodeToken("pkg-1", "download-token", server.URL)
	require.NoError(t, err)

	err = EnrollAgentFromToken(context.Background(), EnrollOptions{
		Token:          token,
		ConfigPath:     configPath,
		CertDir:        certDir,
		NATSCredsPath:  credsPath,
		HTTPClient:     server.Client(),
		RestartService: noopRestartService,
	})
	require.NoError(t, err)

	var config map[string]interface{}
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(data, &config))

	assert.NotContains(t, config, "nats_url")
	assert.NotContains(t, config, "nats_creds_file")
	assert.False(t, fileExists(credsPath))

	backups, err := filepath.Glob(credsPath + ".bak.*")
	require.NoError(t, err)
	require.Len(t, backups, 1)
	creds, err := os.ReadFile(backups[0])
	require.NoError(t, err)
	assert.Equal(t, "existing-creds", string(creds))
}

func TestEnrollAgentIgnoresLegacyNATSCredsFromBundle(t *testing.T) {
	t.Setenv(onboardingTokenPrivateKeyEnv, testOnboardingTokenPrivateKey)
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	dir := t.TempDir()
	configPath := filepath.Join(dir, "agent.json")
	certDir := filepath.Join(dir, "certs")
	credsPath := filepath.Join(dir, "creds", "nats-agent.creds")

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/api/edge-packages/pkg-1/bundle", r.URL.Path)
		_, err := testAgentBundleWith(t, withNATSCreds("replacement-creds")).WriteTo(w)
		if !assert.NoError(t, err) {
			return
		}
	}))
	defer server.Close()

	token, err := EncodeToken("pkg-1", "download-token", server.URL)
	require.NoError(t, err)

	err = EnrollAgentFromToken(context.Background(), EnrollOptions{
		Token:          token,
		ConfigPath:     configPath,
		CertDir:        certDir,
		NATSCredsPath:  credsPath,
		HTTPClient:     server.Client(),
		RestartService: noopRestartService,
	})
	require.NoError(t, err)

	assert.False(t, fileExists(credsPath))

	var config map[string]interface{}
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(data, &config))
	assert.NotContains(t, config, "nats_creds_file")
	assert.NotContains(t, config, "nats_url")
}

func TestEnrollAgentCoreHostOverridesEmbeddedTokenURL(t *testing.T) {
	t.Setenv(onboardingTokenPrivateKeyEnv, testOnboardingTokenPrivateKey)
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	dir := t.TempDir()
	bundle := testAgentBundle(t, "")
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/api/edge-packages/pkg-override/bundle", r.URL.Path)
		if _, err := bundle.WriteTo(w); err != nil {
			t.Errorf("write agent bundle response: %v", err)
		}
	}))
	defer server.Close()

	token, err := EncodeToken("pkg-override", "download-token", "https://serviceradar-web-ng")
	require.NoError(t, err)

	err = EnrollAgentFromToken(context.Background(), EnrollOptions{
		Token:          token,
		CoreHost:       server.URL,
		ConfigPath:     filepath.Join(dir, "agent.json"),
		CertDir:        filepath.Join(dir, "certs"),
		HTTPClient:     server.Client(),
		RestartService: noopRestartService,
	})
	require.NoError(t, err)
}

func TestEnrollAgentValidatesExplicitCoreHostOverride(t *testing.T) {
	t.Setenv(onboardingTokenPrivateKeyEnv, testOnboardingTokenPrivateKey)
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	token, err := EncodeToken("pkg-override", "download-token", "https://valid.example.com")
	require.NoError(t, err)

	err = EnrollAgentFromToken(context.Background(), EnrollOptions{
		Token:    token,
		CoreHost: "http://insecure.example.com",
	})
	require.ErrorIs(t, err, ErrCoreAPIURLMustUseHTTPS)
}

func TestEnrollCollectorInstallsRoleScopedNATSCredsAndRewritesConfig(t *testing.T) {
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	dir := t.TempDir()
	configDir := filepath.Join(dir, "config")
	certsDir := filepath.Join(dir, "certs")
	credsDir := filepath.Join(dir, "creds")

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/api/collectors/collector-pkg/bundle", r.URL.Path)
		assert.Equal(t, "collector-secret", r.Header.Get(downloadTokenHeader))
		_, err := testCollectorBundle(t).WriteTo(w)
		if !assert.NoError(t, err) {
			return
		}
	}))
	defer server.Close()

	token := signedCollectorToken(t, server.URL, "collector-pkg", "collector-secret")
	err := EnrollCollectorFromToken(context.Background(), CollectorEnrollOptions{
		Token:      token,
		ConfigDir:  configDir,
		CertsDir:   certsDir,
		CredsDir:   credsDir,
		HTTPClient: server.Client(),
	})
	require.NoError(t, err)

	scopedCredsPath := filepath.Join(credsDir, defaultCollectorNATSCredsName)
	creds, err := os.ReadFile(scopedCredsPath)
	require.NoError(t, err)
	assert.Equal(t, "collector-creds", string(creds))
	assert.False(t, fileExists(filepath.Join(credsDir, bundleCollectorNATSCredsName)))

	config, err := os.ReadFile(filepath.Join(configDir, "collector.toml"))
	require.NoError(t, err)
	assert.Contains(t, string(config), scopedCredsPath)
	assert.NotContains(t, string(config), legacySharedNATSCredsPath)
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

func TestParseCollectorTokenExplicitBaseURLOverridesEmbeddedURL(t *testing.T) {
	token := signedCollectorToken(t, "https://stale.example.com", "pkg-1", "secret")
	payload, err := parseCollectorToken(token, "https://current.example.com/")
	require.NoError(t, err)
	require.Equal(t, "https://current.example.com", payload.BaseURL)
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

// noopRestartService stubs out the post-enrollment systemctl restart so the
// agent enrollment tests exercise config/credential placement without touching
// the host's service manager (which fails with "Interactive authentication
// required" off-root and would otherwise make these tests environment-dependent).
func noopRestartService(context.Context) error { return nil }

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

func testCollectorBundle(t *testing.T) *bytes.Reader {
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

	writeBundleFile("collector-package/config/collector.toml", []byte(`nats_creds_file = "/etc/serviceradar/creds/nats.creds"`))
	writeBundleFile("collector-package/certs/collector.pem", []byte("cert"))
	writeBundleFile("collector-package/certs/collector-key.pem", []byte("key"))
	writeBundleFile("collector-package/certs/ca-chain.pem", []byte("ca"))
	writeBundleFile("collector-package/creds/nats.creds", []byte("collector-creds"))

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

func TestAgentRestartCommandMatchesEachInstaller(t *testing.T) {
	cases := map[string][]string{
		"linux":   {"systemctl", "restart", "serviceradar-agent"},
		"darwin":  {"launchctl", "kickstart", "-k", "system/com.serviceradar.agent"},
		"windows": {"powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "Restart-Service -Name ServiceRadarAgent"},
		"plan9":   nil,
	}
	for goos, want := range cases {
		got := agentRestartCommand(goos)
		if strings.Join(got, " ") != strings.Join(want, " ") {
			t.Errorf("agentRestartCommand(%q) = %q, want %q", goos, got, want)
		}
	}
}

func TestAgentOverridesPathStaysBesideTheWindowsConfig(t *testing.T) {
	if got := agentOverridesPathFor("windows", "", `C:\ProgramData\ServiceRadar\config\agent.json`); got != `C:\ProgramData\ServiceRadar\config\kv-overrides.env` {
		t.Fatalf("windows overrides path = %q", got)
	}
	if got := agentOverridesPathFor("linux", "", "/etc/serviceradar/agent.json"); got != defaultAgentOverridesPath {
		t.Fatalf("linux overrides path = %q, want %q", got, defaultAgentOverridesPath)
	}
	if got := agentOverridesPathFor("windows", "  /custom/overrides.env ", `C:\x\agent.json`); got != "/custom/overrides.env" {
		t.Fatalf("explicit overrides path ignored: %q", got)
	}
}
