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
	"fmt"
	"strings"
)

func NormalizeDesktopCredentialGrant(
	grant DesktopCredentialGrant,
	target DesktopTarget,
) (DesktopCredentialGrant, error) {
	return NormalizeDesktopCredentialGrantAt(grant, target, nowUnix())
}

// NormalizeDesktopCredentialGrantAt validates a desktop credential grant at a
// caller-provided Unix timestamp. Tests and adapters with trusted clocks can
// use this to make brokered-secret TTL decisions explicit.
func NormalizeDesktopCredentialGrantAt(
	grant DesktopCredentialGrant,
	target DesktopTarget,
	nowUnix int64,
) (DesktopCredentialGrant, error) {
	grant.Mode = strings.TrimSpace(grant.Mode)
	grant.Username = strings.TrimSpace(grant.Username)
	grant.CredentialSecretRef = strings.TrimSpace(grant.CredentialSecretRef)
	grant.ActorID = strings.TrimSpace(grant.ActorID)
	grant.SessionID = strings.TrimSpace(grant.SessionID)
	grant.TargetID = strings.TrimSpace(grant.TargetID)
	grant.RouteID = strings.TrimSpace(grant.RouteID)

	if grant.Mode == "" {
		grant.Mode = target.Credential.Mode
	}
	if grant.Mode != target.Credential.Mode {
		return grant, fmt.Errorf("%w: credential grant mode does not match target policy", ErrInvalidDesktopTarget)
	}
	if grant.TargetID == "" {
		if grant.Mode == DesktopCredentialModeBrokeredSecret {
			return grant, fmt.Errorf("%w: brokered credential grant requires target binding", ErrInvalidDesktopTarget)
		}
		grant.TargetID = target.TargetID
	}
	if grant.TargetID != target.TargetID {
		return grant, fmt.Errorf("%w: credential grant target mismatch", ErrInvalidDesktopTarget)
	}

	switch grant.Mode {
	case DesktopCredentialModeBrokeredSecret:
		if grant.CredentialSecretRef == "" {
			return grant, fmt.Errorf("%w: brokered credential grant requires secret reference", ErrInvalidDesktopTarget)
		}
		if grant.CredentialSecretRef != target.Credential.CredentialSecretRef {
			return grant, fmt.Errorf("%w: brokered credential grant secret mismatch", ErrInvalidDesktopTarget)
		}
		if grant.Password != "" {
			return grant, fmt.Errorf("%w: brokered credential grant must not include password", ErrInvalidDesktopTarget)
		}
		if grant.ActorID == "" || grant.SessionID == "" || grant.RouteID == "" || grant.ExpiresUnix <= 0 {
			return grant, fmt.Errorf("%w: brokered credential grant requires actor, session, route, and ttl binding", ErrInvalidDesktopTarget)
		}
		if nowUnix > 0 && grant.ExpiresUnix <= nowUnix {
			return grant, fmt.Errorf("%w: brokered credential grant expired", ErrInvalidDesktopTarget)
		}
	case DesktopCredentialModeMemoryUser:
		if grant.Username == "" || grant.Password == "" {
			return grant, fmt.Errorf("%w: memory user credential grant requires username and password", ErrInvalidDesktopTarget)
		}
		if !desktopStringListAllows(target.Credential.AllowedPrincipals, grant.Username) {
			return grant, fmt.Errorf("%w: credential grant principal not allowed by target policy", ErrInvalidDesktopTarget)
		}
	}

	return grant, nil
}
