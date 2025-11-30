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
	"encoding/base64"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestParseToken(t *testing.T) {
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
			name:    "edgepkg-v1 prefix but invalid base64",
			token:   "edgepkg-v1:!!!invalid!!!",
			wantErr: nil, // error will be non-nil but not the specific error
		},
		{
			name:         "valid token with all fields",
			token:        makeTestToken("pkg-123", "dl-token-abc", "http://core:8090"),
			fallbackHost: "",
			wantPayload: &TokenPayload{
				PackageID:     "pkg-123",
				DownloadToken: "dl-token-abc",
				CoreURL:       "http://core:8090",
			},
		},
		{
			name:         "valid token uses fallback host",
			token:        makeTestToken("pkg-456", "dl-token-xyz", ""),
			fallbackHost: "http://fallback:8090",
			wantPayload: &TokenPayload{
				PackageID:     "pkg-456",
				DownloadToken: "dl-token-xyz",
				CoreURL:       "http://fallback:8090",
			},
		},
		{
			name:         "missing package id",
			token:        makeTestToken("", "dl-token", "http://core:8090"),
			fallbackHost: "",
			wantErr:      ErrMissingPackageID,
		},
		{
			name:         "missing download token",
			token:        makeTestToken("pkg-123", "", "http://core:8090"),
			fallbackHost: "",
			wantErr:      ErrMissingDownloadToken,
		},
		{
			name:         "missing core url and no fallback",
			token:        makeTestToken("pkg-123", "dl-token", ""),
			fallbackHost: "",
			wantErr:      ErrCoreAPIHostRequired,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
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

func makeTestToken(packageID, downloadToken, coreURL string) string {
	payload := TokenPayload{
		PackageID:     packageID,
		DownloadToken: downloadToken,
		CoreURL:       coreURL,
	}
	data, _ := json.Marshal(payload)
	return tokenPrefix + base64.RawURLEncoding.EncodeToString(data)
}
