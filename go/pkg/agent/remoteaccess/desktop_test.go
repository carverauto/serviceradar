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

const (
	desktopTestTargetID            = "rdp-target-1"
	desktopTestAgentID             = "agent-1"
	remoteAccessTestGatewayID      = "gateway-1"
	desktopTestHost                = "windows.internal"
	desktopTestPassword            = "secret"
	desktopTestActorID             = "user-1"
	desktopTestBrokeredSecret      = "secretref:rdp/admin"
	remoteAccessTestOtherSessionID = "other-session"
	desktopTestExpiresUnix         = 4_102_444_800
	desktopTestCABundlePEM         = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
)

func validDesktopTarget() DesktopTarget {
	return DesktopTarget{
		TargetID: desktopTestTargetID,
		Protocol: ProtocolRDP,
		Route: DesktopRoute{
			SelectedAgentID: desktopTestAgentID,
		},
		Upstream: DesktopUpstream{
			Host: desktopTestHost,
			Port: DesktopDefaultRDPPort,
		},
		TLS: DesktopTLSPolicy{
			Mode: DesktopTLSModeVerify,
		},
		Credential: DesktopCredentialPolicy{
			Mode:              DesktopCredentialModeMemoryUser,
			AllowedPrincipals: []string{"alice"},
		},
	}
}

func validDesktopMemoryGrant(sessionID string) *DesktopCredentialGrant {
	return &DesktopCredentialGrant{
		Mode:      DesktopCredentialModeMemoryUser,
		Username:  "alice",
		Password:  desktopTestPassword,
		ActorID:   desktopTestActorID,
		SessionID: sessionID,
		TargetID:  desktopTestTargetID,
		RouteID:   desktopTestAgentID,
	}
}
