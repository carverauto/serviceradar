/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package mtls

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	testOnboardingTokenPrivateSeed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
	testOnboardingTokenPublicKey   = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
)

func TestParseToken(t *testing.T) {
	t.Setenv(onboardingTokenPublicKeyEnv, testOnboardingTokenPublicKey)

	tests := []struct {
		name         string
		token        string
		fallbackHost string
		wantErr      error
		wantPayload  *TokenPayload
	}{
		{
			name:    "empty token",
			token:   "",
			wantErr: ErrTokenRequired,
		},
		{
			name:    "whitespace only token",
			token:   "   ",
			wantErr: ErrTokenRequired,
		},
		{
			name:    "unsupported format",
			token:   "invalid-token-format",
			wantErr: ErrUnsupportedTokenFormat,
		},
		{
			name:         "valid token with all fields",
			token:        makeSignedTestToken(t, "pkg-123", "dl-token-abc", "https://core:8090"),
			fallbackHost: "",
			wantPayload: &TokenPayload{
				PackageID:     "pkg-123",
				DownloadToken: "dl-token-abc",
				CoreURL:       "https://core:8090",
			},
		},
		{
			name:         "missing package id",
			token:        makeSignedTestToken(t, "", "dl-token", "https://core:8090"),
			fallbackHost: "",
			wantErr:      ErrMissingPackageID,
		},
		{
			name:         "missing download token",
			token:        makeSignedTestToken(t, "pkg-123", "", "https://core:8090"),
			fallbackHost: "",
			wantErr:      ErrMissingDownloadToken,
		},
		{
			name:         "signed token missing public key configuration",
			token:        makeSignedTestToken(t, "pkg-123", "dl-token", "https://core:8090"),
			fallbackHost: "",
			wantErr:      ErrTokenPublicKeyRequired,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if errors.Is(tt.wantErr, ErrTokenPublicKeyRequired) {
				t.Setenv(onboardingTokenPublicKeyEnv, "")
			}
			payload, err := ParseToken(tt.token, tt.fallbackHost)

			if tt.wantErr != nil {
				require.Error(t, err)
				assert.ErrorIs(t, err, tt.wantErr)
				return
			}

			if tt.wantPayload != nil {
				require.NoError(t, err)
				assert.Equal(t, tt.wantPayload.PackageID, payload.PackageID)
				assert.Equal(t, tt.wantPayload.DownloadToken, payload.DownloadToken)
				assert.Equal(t, tt.wantPayload.CoreURL, payload.CoreURL)
			}
		})
	}
}

func makeSignedTestToken(t *testing.T, packageID, downloadToken, coreURL string) string {
	t.Helper()

	seed, err := base64.StdEncoding.DecodeString(testOnboardingTokenPrivateSeed)
	require.NoError(t, err)

	privateKey := ed25519.NewKeyFromSeed(seed)
	payload := TokenPayload{
		PackageID:     packageID,
		DownloadToken: downloadToken,
		CoreURL:       coreURL,
	}
	data, err := json.Marshal(payload)
	require.NoError(t, err)

	signature := ed25519.Sign(privateKey, data)
	return tokenV2Prefix +
		base64.RawURLEncoding.EncodeToString(data) +
		onboardingTokenSignatureSep +
		base64.RawURLEncoding.EncodeToString(signature)
}
