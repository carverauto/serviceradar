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

package accounts

import (
	"fmt"
	"time"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
)

// UserCredentialType specifies the purpose of the credentials.
type UserCredentialType string

const (
	CredentialTypeCollector UserCredentialType = "collector"
	CredentialTypeService   UserCredentialType = "service"
	CredentialTypeAdmin     UserCredentialType = "admin"
)

// UserPermissions defines publish/subscribe permissions.
type UserPermissions struct {
	PublishAllow   []string `json:"publish_allow"`
	PublishDeny    []string `json:"publish_deny"`
	SubscribeAllow []string `json:"subscribe_allow"`
	SubscribeDeny  []string `json:"subscribe_deny"`
	AllowResponses bool     `json:"allow_responses"`
	MaxResponses   int32    `json:"max_responses"`
}

// UserCredentials contains the generated NATS user credentials.
type UserCredentials struct {
	UserPublicKey    string    `json:"user_public_key"`
	UserJWT          string    `json:"user_jwt"`
	CredsFileContent string    `json:"creds_file_content"`
	ExpiresAt        time.Time `json:"expires_at,omitempty"`
}

// GenerateUserCredentials creates NATS credentials for a user in a tenant's account.
// The accountSeed is the tenant's account private key (passed from Elixir storage).
func GenerateUserCredentials(
	tenantSlug string,
	accountSeed string,
	userName string,
	credType UserCredentialType,
	permissions *UserPermissions,
	expirationSeconds int64,
) (*UserCredentials, error) {
	// Parse account seed to get key pair for signing
	accountKP, err := nkeys.FromSeed([]byte(accountSeed))
	if err != nil {
		return nil, fmt.Errorf("invalid account seed: %w", err)
	}

	accountPublicKey, err := accountKP.PublicKey()
	if err != nil {
		return nil, fmt.Errorf("failed to get account public key: %w", err)
	}

	// Generate user key pair
	userKP, err := nkeys.CreateUser()
	if err != nil {
		return nil, fmt.Errorf("failed to create user key: %w", err)
	}

	userPublicKey, err := userKP.PublicKey()
	if err != nil {
		return nil, fmt.Errorf("failed to get user public key: %w", err)
	}

	userSeed, err := userKP.Seed()
	if err != nil {
		return nil, fmt.Errorf("failed to get user seed: %w", err)
	}

	// Create user claims
	claims := jwt.NewUserClaims(userPublicKey)
	claims.Name = userName
	claims.IssuerAccount = accountPublicKey

	// Apply permissions based on credential type
	applyUserPermissions(claims, tenantSlug, credType, permissions)

	// Set expiration if specified
	var expiresAt time.Time
	if expirationSeconds > 0 {
		expiresAt = time.Now().Add(time.Duration(expirationSeconds) * time.Second)
		claims.Expires = expiresAt.Unix()
	}

	// Sign the user claims with the account key
	userJWT, err := claims.Encode(accountKP)
	if err != nil {
		return nil, fmt.Errorf("failed to sign user claims: %w", err)
	}

	// Format as .creds file content
	credsContent := formatCredsFile(userJWT, userSeed)

	return &UserCredentials{
		UserPublicKey:    userPublicKey,
		UserJWT:          userJWT,
		CredsFileContent: credsContent,
		ExpiresAt:        expiresAt,
	}, nil
}

// applyUserPermissions sets permissions on user claims based on credential type.
func applyUserPermissions(
	claims *jwt.UserClaims,
	tenantSlug string,
	credType UserCredentialType,
	custom *UserPermissions,
) {
	// Start with type-based defaults
	switch credType {
	case CredentialTypeCollector:
		// Collectors can publish to their tenant's subjects (mapped by account)
		// and subscribe to responses
		claims.Permissions.Pub.Allow.Add("events.>")
		claims.Permissions.Pub.Allow.Add("snmp.traps")
		claims.Permissions.Pub.Allow.Add("logs.>")
		claims.Permissions.Pub.Allow.Add("telemetry.>")
		claims.Permissions.Pub.Allow.Add("netflow.>")
		claims.Permissions.Sub.Allow.Add("_INBOX.>")
		claims.Permissions.Resp = &jwt.ResponsePermission{
			MaxMsgs: 1,
			Expires: time.Minute,
		}

	case CredentialTypeService:
		// Internal services have broader permissions within tenant scope
		claims.Permissions.Pub.Allow.Add(fmt.Sprintf("%s.>", tenantSlug))
		claims.Permissions.Sub.Allow.Add(fmt.Sprintf("%s.>", tenantSlug))
		claims.Permissions.Sub.Allow.Add("_INBOX.>")
		claims.Permissions.Resp = &jwt.ResponsePermission{
			MaxMsgs: 100,
			Expires: time.Minute * 5,
		}

	case CredentialTypeAdmin:
		// Admin can read from tenant subjects but not publish
		claims.Permissions.Sub.Allow.Add(fmt.Sprintf("%s.>", tenantSlug))
		claims.Permissions.Sub.Allow.Add("_INBOX.>")
		// Limited publish for admin operations
		claims.Permissions.Pub.Allow.Add(fmt.Sprintf("%s.admin.>", tenantSlug))
	}

	// Override with custom permissions if provided
	if custom != nil {
		if len(custom.PublishAllow) > 0 {
			claims.Permissions.Pub.Allow = jwt.StringList{}
			for _, p := range custom.PublishAllow {
				claims.Permissions.Pub.Allow.Add(p)
			}
		}
		if len(custom.PublishDeny) > 0 {
			for _, p := range custom.PublishDeny {
				claims.Permissions.Pub.Deny.Add(p)
			}
		}
		if len(custom.SubscribeAllow) > 0 {
			claims.Permissions.Sub.Allow = jwt.StringList{}
			for _, p := range custom.SubscribeAllow {
				claims.Permissions.Sub.Allow.Add(p)
			}
		}
		if len(custom.SubscribeDeny) > 0 {
			for _, p := range custom.SubscribeDeny {
				claims.Permissions.Sub.Deny.Add(p)
			}
		}
		if custom.AllowResponses {
			maxMsgs := 1
			if custom.MaxResponses > 0 {
				maxMsgs = int(custom.MaxResponses)
			}
			claims.Permissions.Resp = &jwt.ResponsePermission{
				MaxMsgs: maxMsgs,
				Expires: time.Minute,
			}
		}
	}
}

// formatCredsFile creates the content of a NATS .creds file.
func formatCredsFile(jwt string, seed []byte) string {
	return fmt.Sprintf(`-----BEGIN NATS USER JWT-----
%s
------END NATS USER JWT------

************************* IMPORTANT *************************
NKEY Seed printed below can be used to sign and prove identity.
NKEYs are sensitive and should be treated as secrets.

-----BEGIN USER NKEY SEED-----
%s
------END USER NKEY SEED------

*************************************************************
`, jwt, string(seed))
}
