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

package edgeonboarding

import (
	"testing"
)

func TestExtractTrustDomain(t *testing.T) {
	tests := []struct {
		name     string
		spiffeID string
		want     string
	}{
		{
			name:     "valid SPIFFE ID with path",
			spiffeID: "spiffe://carverauto.dev/ns/edge/poller-1",
			want:     "carverauto.dev",
		},
		{
			name:     "valid SPIFFE ID with multiple path segments",
			spiffeID: "spiffe://example.com/workload/service/instance",
			want:     "example.com",
		},
		{
			name:     "SPIFFE ID with trust domain only",
			spiffeID: "spiffe://trustdomain.io",
			want:     "trustdomain.io",
		},
		{
			name:     "SPIFFE ID with trust domain and trailing slash",
			spiffeID: "spiffe://trustdomain.io/",
			want:     "trustdomain.io",
		},
		{
			name:     "trust domain without spiffe prefix",
			spiffeID: "carverauto.dev/ns/edge/poller-1",
			want:     "carverauto.dev",
		},
		{
			name:     "trust domain only without spiffe prefix",
			spiffeID: "example.com",
			want:     "example.com",
		},
		{
			name:     "empty string",
			spiffeID: "",
			want:     "unknown",
		},
		{
			name:     "only spiffe prefix",
			spiffeID: "spiffe://",
			want:     "unknown",
		},
		{
			name:     "trust domain with subdomain",
			spiffeID: "spiffe://sub.domain.example.com/workload/app",
			want:     "sub.domain.example.com",
		},
		{
			name:     "trust domain with port (invalid but should handle)",
			spiffeID: "spiffe://example.com:8080/workload",
			want:     "example.com:8080",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := extractTrustDomain(tt.spiffeID)
			if got != tt.want {
				t.Errorf("extractTrustDomain(%q) = %q, want %q", tt.spiffeID, got, tt.want)
			}
		})
	}
}
