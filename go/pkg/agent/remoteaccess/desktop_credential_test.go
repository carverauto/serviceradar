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
	target.Credential.CredentialSecretRef = desktopTestBrokeredSecret
	target.ApprovalRequired = true

	validGrant := DesktopCredentialGrant{
		Mode:                DesktopCredentialModeBrokeredSecret,
		CredentialSecretRef: desktopTestBrokeredSecret,
		ActorID:             desktopTestActorID,
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
		Password:  desktopTestPassword,
		ActorID:   desktopTestActorID,
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

	grant.TargetID = ""
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing target binding error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
	grant.TargetID = desktopTestTargetID

	grant.SessionID = ""
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing session binding error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
	grant.SessionID = "session-1"

	grant.Password = ""
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing password error = %v, want %v", err, ErrInvalidDesktopTarget)
	}

	grant.Username = "mallory"
	grant.Password = desktopTestPassword
	grant.ActorID = ""
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing actor binding error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
	grant.ActorID = desktopTestActorID

	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("disallowed principal error = %v, want %v", err, ErrInvalidDesktopTarget)
	}

	grant.Username = "alice"
	target.Credential.AllowedPrincipals = nil
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing principal allowlist error = %v, want %v", err, ErrInvalidDesktopTarget)
	}

	target.Credential.AllowedPrincipals = []string{"Alice"}
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("case-mismatched principal error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestValidateDesktopOpenCredentialGrantRequiresGrantForSecretModes(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	if _, err := ValidateDesktopOpenCredentialGrant(
		DesktopOpenPayload{Target: target},
		"session-1",
		1_778_000_000,
	); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing memory grant error = %v, want %v", err, ErrInvalidDesktopTarget)
	}

	target.Credential.Mode = DesktopCredentialModeBrokeredSecret
	target.Credential.CredentialSecretRef = desktopTestBrokeredSecret
	target.ApprovalRequired = true
	if _, err := ValidateDesktopOpenCredentialGrant(
		DesktopOpenPayload{Target: target},
		"session-1",
		1_778_000_000,
	); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing brokered grant error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestValidateDesktopOpenCredentialGrantAllowsGrantlessNonSecretModes(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Credential.Mode = DesktopCredentialModeDomainDelegation

	grant, err := ValidateDesktopOpenCredentialGrant(
		DesktopOpenPayload{Target: target},
		"session-1",
		1_778_000_000,
	)
	if err != nil {
		t.Fatalf("ValidateDesktopOpenCredentialGrant returned error: %v", err)
	}
	if grant != nil {
		t.Fatalf("grant = %#v, want nil", grant)
	}
}

func TestValidateDesktopOpenCredentialGrantNormalizesAndBindsSession(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Credential.AllowedPrincipals = []string{"alice"}
	grant := validDesktopMemoryGrant("session-1")
	payload := DesktopOpenPayload{
		ActorID:         desktopTestActorID,
		Target:          target,
		CredentialGrant: grant,
	}

	got, err := ValidateDesktopOpenCredentialGrant(payload, "session-1", 1_778_000_000)
	if err != nil {
		t.Fatalf("ValidateDesktopOpenCredentialGrant returned error: %v", err)
	}
	if got == nil || got.Username != "alice" || got.TargetID != desktopTestTargetID {
		t.Fatalf("grant = %#v", got)
	}

	payload.ActorID = "user-2"
	if _, err := ValidateDesktopOpenCredentialGrant(
		payload,
		"session-1",
		1_778_000_000,
	); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("mismatched actor error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
	payload.ActorID = desktopTestActorID

	grant.SessionID = remoteAccessTestOtherSessionID
	if _, err := ValidateDesktopOpenCredentialGrant(
		payload,
		"session-1",
		1_778_000_000,
	); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("mismatched session error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestDesktopCredentialGrantDropSensitive(t *testing.T) {
	t.Parallel()

	grant := DesktopCredentialGrant{
		Mode:                DesktopCredentialModeMemoryUser,
		Username:            "alice",
		Password:            desktopTestPassword,
		CredentialSecretRef: desktopTestBrokeredSecret,
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
