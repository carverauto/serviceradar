/*
 * Copyright 2026 Carver Automation Corporation.
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

package syncsources

import "testing"

func TestNormalizeIdentityScope(t *testing.T) {
	for _, tc := range []struct {
		name  string
		scope string
		want  string
	}{
		{"empty", "", ""},
		{"blank", "   ", ""},
		{"plain", "main", "main"},
		{"trims and lowercases", "  Main Source ", "main-source"},
		{"collapses colons", "default:armis:svc-1", "default-armis-svc-1"},
		{"collapses mixed runs", "a::b  c", "a-b-c"},
		{"uuid survives", "9f3a2c1d-4b5e-4f6a-8c7d-9e0f1a2b3c4d", "9f3a2c1d-4b5e-4f6a-8c7d-9e0f1a2b3c4d"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := NormalizeIdentityScope(tc.scope); got != tc.want {
				t.Fatalf("NormalizeIdentityScope(%q) = %q, want %q", tc.scope, got, tc.want)
			}
		})
	}
}

func TestScopedIntegrationID(t *testing.T) {
	got := ScopedIntegrationID("armis", "main", "device", "18497")
	if got != "armis:main:device:18497" {
		t.Fatalf("ScopedIntegrationID = %q, want %q", got, "armis:main:device:18497")
	}

	for _, tc := range []struct {
		name       string
		sourceType string
		scope      string
		kind       string
		nativeID   string
	}{
		{"empty source type", "", "main", "device", "18497"},
		{"empty scope", "armis", "", "device", "18497"},
		{"blank scope", "armis", "   ", "device", "18497"},
		{"empty kind", "armis", "main", "", "18497"},
		{"empty native id", "armis", "main", "device", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := ScopedIntegrationID(tc.sourceType, tc.scope, tc.kind, tc.nativeID); got != "" {
				t.Fatalf("ScopedIntegrationID(%q, %q, %q, %q) = %q, want empty",
					tc.sourceType, tc.scope, tc.kind, tc.nativeID, got)
			}
		})
	}
}
