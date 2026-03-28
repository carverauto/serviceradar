package edgeonboarding

import (
	"testing"

	"github.com/stretchr/testify/require"
)

const (
	testOnboardingTokenPrivateKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
	testOnboardingTokenPublicKey  = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
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
	require.Empty(t, payload.CoreURL)
}

func TestParseLegacyToken(t *testing.T) {
	payload, err := parseOnboardingToken("pkg-001:token-xyz", "", "")
	require.NoError(t, err)
	require.Equal(t, "pkg-001", payload.PackageID)
	require.Equal(t, "token-xyz", payload.DownloadToken)
	require.Empty(t, payload.CoreURL)
}

func TestParseLegacyTokenWithCoreURL(t *testing.T) {
	payload, err := parseOnboardingToken("https://demo.example.com@pkg-002/token-abc", "", "")
	require.NoError(t, err)
	require.Equal(t, "pkg-002", payload.PackageID)
	require.Equal(t, "token-abc", payload.DownloadToken)
	require.Empty(t, payload.CoreURL)
}

func TestParseTokenFallsBackToPackageID(t *testing.T) {
	payload, err := parseOnboardingToken("token-only", "pkg-fallback", "")
	require.NoError(t, err)
	require.Equal(t, "pkg-fallback", payload.PackageID)
	require.Equal(t, "token-only", payload.DownloadToken)
}

func TestEncodeTokenHelper(t *testing.T) {
	t.Setenv(onboardingTokenPrivateKeyEnv, testOnboardingTokenPrivateKey)
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	token, err := EncodeToken("pkg-123", "dl-456", "https://demo.example.com")
	require.NoError(t, err)
	require.NotEmpty(t, token)
	require.Contains(t, token, tokenV2Prefix)

	payload, err := parseOnboardingToken(token, "", "")
	require.NoError(t, err)
	require.Equal(t, "pkg-123", payload.PackageID)
	require.Equal(t, "dl-456", payload.DownloadToken)
	require.Equal(t, "https://demo.example.com", payload.CoreURL)
}

func TestParseSignedTokenRejectsTampering(t *testing.T) {
	t.Setenv(onboardingTokenPrivateKeyEnv, testOnboardingTokenPrivateKey)
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	token, err := EncodeToken("pkg-123", "dl-456", "https://demo.example.com")
	require.NoError(t, err)

	tampered := token[:len(token)-1] + "A"
	_, err = parseOnboardingToken(tampered, "", "")
	require.ErrorIs(t, err, ErrOnboardingTokenInvalidSignature)
}

func TestEncodeTokenValidatesInput(t *testing.T) {
	_, err := EncodeToken("", "token", "https://demo")
	require.ErrorIs(t, err, ErrPackageIDEmpty)

	_, err = EncodeToken("pkg", " ", "https://demo")
	require.ErrorIs(t, err, ErrDownloadTokenEmpty)
}
