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

package tenant

import (
	"errors"
	"testing"
)

func TestParseCN(t *testing.T) {
	tests := []struct {
		name        string
		cn          string
		wantInfo    *Info
		wantErr     error
		errContains string
	}{
		{
			name: "valid CN",
			cn:   "agent-001.partition-1.acme-corp.serviceradar",
			wantInfo: &Info{
				ComponentID: "agent-001",
				PartitionID: "partition-1",
				TenantSlug:  "acme-corp",
			},
		},
		{
			name: "valid CN with dashes in tenant",
			cn:   "poller-main.us-east-1.my-company-inc.serviceradar",
			wantInfo: &Info{
				ComponentID: "poller-main",
				PartitionID: "us-east-1",
				TenantSlug:  "my-company-inc",
			},
		},
		{
			name: "valid CN with simple names",
			cn:   "checker.default.demo.serviceradar",
			wantInfo: &Info{
				ComponentID: "checker",
				PartitionID: "default",
				TenantSlug:  "demo",
			},
		},
		{
			name:        "too few parts",
			cn:          "agent.acme-corp.serviceradar",
			wantErr:     ErrInvalidCNFormat,
			errContains: "expected 4 parts",
		},
		{
			name:        "too many parts",
			cn:          "agent.extra.partition-1.acme-corp.serviceradar",
			wantErr:     ErrInvalidCNFormat,
			errContains: "expected 4 parts",
		},
		{
			name:        "wrong suffix",
			cn:          "agent-001.partition-1.acme-corp.example",
			wantErr:     ErrInvalidCNFormat,
			errContains: "expected suffix",
		},
		{
			name:        "empty string",
			cn:          "",
			wantErr:     ErrInvalidCNFormat,
			errContains: "expected 4 parts",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			info, err := ParseCN(tt.cn)

			if tt.wantErr != nil {
				if err == nil {
					t.Errorf("ParseCN(%q) expected error, got nil", tt.cn)
					return
				}
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("ParseCN(%q) error = %v, want %v", tt.cn, err, tt.wantErr)
				}
				if tt.errContains != "" && !contains(err.Error(), tt.errContains) {
					t.Errorf("ParseCN(%q) error = %q, want containing %q", tt.cn, err.Error(), tt.errContains)
				}
				return
			}

			if err != nil {
				t.Errorf("ParseCN(%q) unexpected error: %v", tt.cn, err)
				return
			}

			if info.ComponentID != tt.wantInfo.ComponentID {
				t.Errorf("ComponentID = %q, want %q", info.ComponentID, tt.wantInfo.ComponentID)
			}
			if info.PartitionID != tt.wantInfo.PartitionID {
				t.Errorf("PartitionID = %q, want %q", info.PartitionID, tt.wantInfo.PartitionID)
			}
			if info.TenantSlug != tt.wantInfo.TenantSlug {
				t.Errorf("TenantSlug = %q, want %q", info.TenantSlug, tt.wantInfo.TenantSlug)
			}
		})
	}
}

func TestInfo_String(t *testing.T) {
	info := &Info{
		TenantSlug:  "acme-corp",
		PartitionID: "partition-1",
		ComponentID: "agent-001",
	}

	got := info.String()
	want := "acme-corp/partition-1/agent-001"

	if got != want {
		t.Errorf("Info.String() = %q, want %q", got, want)
	}
}

func TestInfo_CN(t *testing.T) {
	info := &Info{
		TenantSlug:  "acme-corp",
		PartitionID: "partition-1",
		ComponentID: "agent-001",
	}

	got := info.CN()
	want := "agent-001.partition-1.acme-corp.serviceradar"

	if got != want {
		t.Errorf("Info.CN() = %q, want %q", got, want)
	}
}

func TestInfo_NATSPrefix(t *testing.T) {
	info := &Info{TenantSlug: "acme-corp"}

	got := info.NATSPrefix()
	want := "acme-corp."

	if got != want {
		t.Errorf("Info.NATSPrefix() = %q, want %q", got, want)
	}
}

func TestInfo_PrefixChannel(t *testing.T) {
	info := &Info{TenantSlug: "acme-corp"}

	tests := []struct {
		channel string
		want    string
	}{
		{"events.poller.health", "acme-corp.events.poller.health"},
		{"agents.status", "acme-corp.agents.status"},
		{"jobs.dispatch", "acme-corp.jobs.dispatch"},
	}

	for _, tt := range tests {
		got := info.PrefixChannel(tt.channel)
		if got != tt.want {
			t.Errorf("PrefixChannel(%q) = %q, want %q", tt.channel, got, tt.want)
		}
	}
}

func TestParseCN_Roundtrip(t *testing.T) {
	original := &Info{
		ComponentID: "agent-001",
		PartitionID: "partition-1",
		TenantSlug:  "acme-corp",
	}

	cn := original.CN()
	parsed, err := ParseCN(cn)
	if err != nil {
		t.Fatalf("ParseCN(%q) failed: %v", cn, err)
	}

	if parsed.ComponentID != original.ComponentID {
		t.Errorf("ComponentID mismatch after roundtrip")
	}
	if parsed.PartitionID != original.PartitionID {
		t.Errorf("PartitionID mismatch after roundtrip")
	}
	if parsed.TenantSlug != original.TenantSlug {
		t.Errorf("TenantSlug mismatch after roundtrip")
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsAt(s, substr, 0))
}

func containsAt(s, substr string, start int) bool {
	for i := start; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
