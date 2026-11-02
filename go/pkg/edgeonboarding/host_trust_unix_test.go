//go:build unix

package edgeonboarding

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/stretchr/testify/require"
)

// A directory other users can replace must not receive the enrolled identity.
// The privileged helper later trusts root-owned bytes at this path, so publishing
// first and chowning afterwards would adopt a substituted identity or CA.
func TestEnrollAgentLeavesMutableHostTrustUnpublished(t *testing.T) {
	dir := t.TempDir()
	trust := filepath.Join(dir, "host-trust")
	require.NoError(t, os.Mkdir(trust, 0o777))
	require.NoError(t, os.Chmod(trust, 0o777))
	planted := []byte("planted-identity")
	identityPath := filepath.Join(trust, "identity.json")
	require.NoError(t, os.WriteFile(identityPath, planted, 0o644))
	if os.Geteuid() == 0 {
		// A service-owned trust directory can replace entries even when the mode
		// is not world-writable. Root enrollment has to take the directory before
		// it publishes, then leave the new identity owned by root.
		require.NoError(t, os.Chown(trust, 65534, 65534))
		require.NoError(t, os.Chown(identityPath, 65534, 65534))
	}

	err := enrollSyntheticAgent(t, dir)
	if os.Geteuid() == 0 {
		require.NoError(t, err)
		got, readErr := os.ReadFile(identityPath)
		require.NoError(t, readErr)
		require.JSONEq(t, `{"agent_id":"agent-enrolled","partition":"edge-a"}`, string(got))
		info, statErr := os.Stat(trust)
		require.NoError(t, statErr)
		require.Zero(t, info.Mode().Perm()&0o022)
		require.Equal(t, 0, statUID(t, trust))
		require.Equal(t, 0, statUID(t, identityPath))
		return
	}

	require.Error(t, err)
	got, readErr := os.ReadFile(identityPath)
	require.NoError(t, readErr)
	require.Equal(t, planted, got)
	_, caErr := os.Stat(filepath.Join(trust, "ca.pem"))
	require.True(t, os.IsNotExist(caErr))
}

func TestEnrollAgentRejectsSymlinkedHostTrust(t *testing.T) {
	dir := t.TempDir()
	outside := filepath.Join(dir, "outside")
	require.NoError(t, os.Mkdir(outside, 0o755))
	kept := []byte("kept-identity")
	require.NoError(t, os.WriteFile(filepath.Join(outside, "identity.json"), kept, 0o644))
	require.NoError(t, os.Symlink(outside, filepath.Join(dir, "host-trust")))

	err := enrollSyntheticAgent(t, dir)
	require.Error(t, err)
	got, readErr := os.ReadFile(filepath.Join(outside, "identity.json"))
	require.NoError(t, readErr)
	require.Equal(t, kept, got)
}

func TestEnrollAgentRejectsSymlinkedTrustParent(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real")
	require.NoError(t, os.Mkdir(real, 0o755))
	link := filepath.Join(dir, "link")
	require.NoError(t, os.Symlink(real, link))

	err := enrollSyntheticAgent(t, link)
	require.Error(t, err)
	_, statErr := os.Stat(filepath.Join(real, "host-trust"))
	require.True(t, os.IsNotExist(statErr))
}

func TestEnrollAgentRepublishesPrivateHostTrust(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, enrollSyntheticAgent(t, dir))
	identityPath := filepath.Join(dir, "host-trust", "identity.json")
	first, err := os.ReadFile(identityPath)
	require.NoError(t, err)
	require.JSONEq(t, `{"agent_id":"agent-enrolled","partition":"edge-a"}`, string(first))

	require.NoError(t, enrollSyntheticAgent(t, dir))
	second, err := os.ReadFile(identityPath)
	require.NoError(t, err)
	require.JSONEq(t, `{"agent_id":"agent-enrolled","partition":"edge-a"}`, string(second))
	info, err := os.Stat(filepath.Join(dir, "host-trust"))
	require.NoError(t, err)
	require.Zero(t, info.Mode().Perm()&0o022)
}

func enrollSyntheticAgent(t *testing.T, dir string) error {
	t.Helper()
	t.Setenv(onboardingTokenPrivateKeyEnv, testOnboardingTokenPrivateKey)
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	ca := []byte("-----BEGIN CERTIFICATE-----\nU1lOVEhFVElD\n-----END CERTIFICATE-----\n")
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, err := testAgentBundleWith(t, withAgentConfig(`{
  "agent_id": "agent-enrolled",
  "partition": "edge-a",
  "host_ip": "203.0.113.10"
}`), withCAChain(ca)).WriteTo(w)
		if err != nil {
			t.Errorf("write agent bundle response: %v", err)
		}
	}))
	t.Cleanup(server.Close)

	token, err := EncodeToken("pkg-trust", "download-token", server.URL)
	if err != nil {
		return err
	}
	return EnrollAgentFromToken(context.Background(), EnrollOptions{
		Token:          token,
		ConfigPath:     filepath.Join(dir, "agent.json"),
		CertDir:        filepath.Join(dir, "certs"),
		HTTPClient:     server.Client(),
		RestartService: noopRestartService,
	})
}

func statUID(t *testing.T, path string) int {
	t.Helper()
	info, err := os.Stat(path)
	require.NoError(t, err)
	stat, ok := info.Sys().(*syscall.Stat_t)
	require.True(t, ok)
	return int(stat.Uid)
}
