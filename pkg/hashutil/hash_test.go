package hashutil

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDecodeSHA256String(t *testing.T) {
	payload := []byte("serviceradar")
	sum := sha256.Sum256(payload)

	cases := []struct {
		name       string
		input      string
		wantHex    string
		shouldFail bool
	}{
		{
			name:    "hex lowercase",
			input:   hex.EncodeToString(sum[:]),
			wantHex: hex.EncodeToString(sum[:]),
		},
		{
			name:    "hex uppercase",
			input:   strings.ToUpper(hex.EncodeToString(sum[:])),
			wantHex: hex.EncodeToString(sum[:]),
		},
		{
			name:    "base64 standard",
			input:   base64.StdEncoding.EncodeToString(sum[:]),
			wantHex: hex.EncodeToString(sum[:]),
		},
		{
			name:    "base64 url",
			input:   base64.URLEncoding.EncodeToString(sum[:]),
			wantHex: hex.EncodeToString(sum[:]),
		},
		{
			name:       "unsupported encoding",
			input:      "not*valid*digest",
			shouldFail: true,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			decoded, err := DecodeSHA256String(tc.input)
			if tc.shouldFail {
				require.Error(t, err)
				return
			}

			require.NoError(t, err)
			require.Equal(t, tc.wantHex, hex.EncodeToString(decoded))
		})
	}
}

func TestCanonicalHexSHA256(t *testing.T) {
	payload := []byte("serviceradar")
	sum := sha256.Sum256(payload)
	base64Digest := base64.StdEncoding.EncodeToString(sum[:])

	hexDigest, err := CanonicalHexSHA256(base64Digest)
	require.NoError(t, err)
	require.Equal(t, hex.EncodeToString(sum[:]), hexDigest)
}

func TestEqualSHA256(t *testing.T) {
	payload := []byte("serviceradar")
	sum := sha256.Sum256(payload)
	hexDigest := hex.EncodeToString(sum[:])
	base64Digest := base64.StdEncoding.EncodeToString(sum[:])

	require.True(t, EqualSHA256(hexDigest, sum))
	require.True(t, EqualSHA256(strings.ToUpper(hexDigest), sum))
	require.True(t, EqualSHA256(base64Digest, sum))
	require.False(t, EqualSHA256("invalid", sum))
}
