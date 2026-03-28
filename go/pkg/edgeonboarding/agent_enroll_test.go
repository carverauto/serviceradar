package edgeonboarding

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
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
