package config

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSanitizeTOML(t *testing.T) {
	raw := []byte(`
# comment
endpoint = "https://example"
token = "top-secret"

[outputs.prometheus]
listen = ":9090"
token = "super-secret"

[inputs.otlp]
address = ":4317"
`)

	deny := []TOMLPath{
		{Table: "", Key: "token"},
		{Table: "outputs.prometheus", Key: "token"},
	}

	filtered := SanitizeTOML(raw, deny)

	require.NotContains(t, string(filtered), `token = "top-secret"`)
	require.NotContains(t, string(filtered), `token = "super-secret"`)
	require.Contains(t, string(filtered), `endpoint = "https://example"`)
	require.Contains(t, string(filtered), `listen = ":9090"`)
}

func TestSanitizeTOMLWildcard(t *testing.T) {
	raw := []byte(`
[outputs.s3]
secret = "abc"

[outputs.gcs]
secret = "def"
`)

	deny := []TOMLPath{
		{Table: "outputs.s3", Key: "*"},
		{Table: "outputs.gcs", Key: "secret"},
	}

	filtered := SanitizeTOML(raw, deny)

	require.NotContains(t, string(filtered), `secret = "abc"`)
	require.NotContains(t, string(filtered), `secret = "def"`)
}
