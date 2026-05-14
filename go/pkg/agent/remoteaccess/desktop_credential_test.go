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

package remoteaccess

import (
	"errors"
	"testing"
)

func TestNormalizeDesktopCredentialGrantEnforcesBrokeredSecretCustody(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Credential.Mode = DesktopCredentialModeBrokeredSecret
	target.Credential.CredentialSecretRef = "secretref:rdp/admin"
	target.ApprovalRequired = true

	validGrant := DesktopCredentialGrant{
		Mode:                DesktopCredentialModeBrokeredSecret,
		CredentialSecretRef: "secretref:rdp/admin",
		ActorID:             "user-1",
		SessionID:           "session-1",
		TargetID:            desktopTestTargetID,
		RouteID:             desktopTestAgentID,
		ExpiresUnix:         desktopTestExpiresUnix,
	}

	if _, err := NormalizeDesktopCredentialGrant(validGrant, target); err != nil {
		t.Fatalf("NormalizeDesktopCredentialGrant returned error: %v", err)
	}

	tests := []struct {
		name   string
		mutate func(*DesktopCredentialGrant)
	}{
		{
			name: "secret mismatch",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.CredentialSecretRef = "secretref:rdp/other"
			},
		},
		{
			name: "password included",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.Password = "not-allowed"
			},
		},
		{
			name: "missing actor binding",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.ActorID = ""
			},
		},
		{
			name: "missing session binding",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.SessionID = ""
			},
		},
		{
			name: "missing target binding",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.TargetID = ""
			},
		},
		{
			name: "missing route binding",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.RouteID = ""
			},
		},
		{
			name: "missing ttl",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.ExpiresUnix = 0
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			grant := validGrant
			tt.mutate(&grant)
			_, err := NormalizeDesktopCredentialGrant(grant, target)
			if !errors.Is(err, ErrInvalidDesktopTarget) {
				t.Fatalf("error = %v, want %v", err, ErrInvalidDesktopTarget)
			}
		})
	}

	if _, err := NormalizeDesktopCredentialGrantAt(
		validGrant,
		target,
		desktopTestExpiresUnix+1,
	); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("expired grant error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestNormalizeDesktopCredentialGrantEnforcesMemoryUserCredential(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Credential.AllowedPrincipals = []string{"alice", "DOMAIN\\bob"}
	grant := DesktopCredentialGrant{
		Mode:      DesktopCredentialModeMemoryUser,
		Username:  "alice",
		Password:  "secret",
		SessionID: "session-1",
		TargetID:  desktopTestTargetID,
	}

	got, err := NormalizeDesktopCredentialGrant(grant, target)
	if err != nil {
		t.Fatalf("NormalizeDesktopCredentialGrant returned error: %v", err)
	}
	if got.TargetID != desktopTestTargetID {
		t.Fatalf("TargetID = %q, want %q", got.TargetID, desktopTestTargetID)
	}

	grant.Password = ""
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing password error = %v, want %v", err, ErrInvalidDesktopTarget)
	}

	grant.Username = "mallory"
	grant.Password = "secret"
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("disallowed principal error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestDesktopCredentialGrantDropSensitive(t *testing.T) {
	t.Parallel()

	grant := DesktopCredentialGrant{
		Mode:                DesktopCredentialModeMemoryUser,
		Username:            "alice",
		Password:            "secret",
		CredentialSecretRef: "secretref:rdp/admin",
		ActorID:             "user-1",
		SessionID:           "session-1",
		TargetID:            desktopTestTargetID,
		RouteID:             desktopTestAgentID,
		ExpiresUnix:         desktopTestExpiresUnix,
	}

	grant.DropSensitive()
	if grant.Username != "" || grant.Password != "" || grant.CredentialSecretRef != "" {
		t.Fatalf("sensitive fields not cleared: %#v", grant)
	}
	if grant.ActorID != "user-1" || grant.SessionID != "session-1" ||
		grant.TargetID != desktopTestTargetID || grant.RouteID != desktopTestAgentID ||
		grant.ExpiresUnix != desktopTestExpiresUnix {
		t.Fatalf("binding fields should be retained: %#v", grant)
	}

	var nilGrant *DesktopCredentialGrant
	nilGrant.DropSensitive()
}
