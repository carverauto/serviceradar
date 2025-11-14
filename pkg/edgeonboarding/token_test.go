package edgeonboarding

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestParseStructuredToken(t *testing.T) {
	raw, err := encodeTokenPayload(tokenPayload{
		PackageID:     "pkg-123",
		DownloadToken: "dl-456",
		CoreURL:       "https://demo.example.com",
	})
	require.NoError(t, err)

	payload, err := parseOnboardingToken(raw, "", "")
	require.NoError(t, err)
	require.Equal(t, "pkg-123", payload.PackageID)
	require.Equal(t, "dl-456", payload.DownloadToken)
	require.Equal(t, "https://demo.example.com", payload.CoreURL)
}

func TestParseLegacyToken(t *testing.T) {
	payload, err := parseOnboardingToken("pkg-001:token-xyz", "", "")
	require.NoError(t, err)
	require.Equal(t, "pkg-001", payload.PackageID)
	require.Equal(t, "token-xyz", payload.DownloadToken)
	require.Equal(t, "", payload.CoreURL)
}

func TestParseLegacyTokenWithCoreURL(t *testing.T) {
	payload, err := parseOnboardingToken("https://demo.example.com@pkg-002/token-abc", "", "")
	require.NoError(t, err)
	require.Equal(t, "pkg-002", payload.PackageID)
	require.Equal(t, "token-abc", payload.DownloadToken)
	require.Equal(t, "https://demo.example.com", payload.CoreURL)
}

func TestParseTokenFallsBackToPackageID(t *testing.T) {
	payload, err := parseOnboardingToken("token-only", "pkg-fallback", "")
	require.NoError(t, err)
	require.Equal(t, "pkg-fallback", payload.PackageID)
	require.Equal(t, "token-only", payload.DownloadToken)
}

func TestEncodeTokenHelper(t *testing.T) {
	token, err := EncodeToken("pkg-123", "dl-456", "https://demo.example.com")
	require.NoError(t, err)
	require.NotEmpty(t, token)

	payload, err := parseOnboardingToken(token, "", "")
	require.NoError(t, err)
	require.Equal(t, "pkg-123", payload.PackageID)
	require.Equal(t, "dl-456", payload.DownloadToken)
	require.Equal(t, "https://demo.example.com", payload.CoreURL)
}

func TestEncodeTokenValidatesInput(t *testing.T) {
	_, err := EncodeToken("", "token", "https://demo")
	require.ErrorIs(t, err, ErrPackageIDEmpty)

	_, err = EncodeToken("pkg", " ", "https://demo")
	require.ErrorIs(t, err, ErrDownloadTokenEmpty)
}
