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

package models

import (
	"time"
)

// User contains information about an authenticated user.
// @Description Information about an authenticated user.
type User struct {
	// Unique identifier for the user
	ID string `json:"id" example:"u-1234567890"`
	// Email address of the user
	Email string `json:"email" example:"user@example.com"`
	// Display name of the user
	Name string `json:"name" example:"John Doe"`
	// Authentication provider (e.g., "local", "google", "github")
	Provider string `json:"provider" example:"google"`
	// When the user account was created
	CreatedAt time.Time `json:"created_at" example:"2025-01-01T00:00:00Z"`
	// When the user account was last updated
	UpdatedAt time.Time `json:"updated_at" example:"2025-04-01T00:00:00Z"`
}

// Token represents authentication tokens for API access.
// @Description Authentication tokens for API access.
type Token struct {
	// JWT access token used for API authorization
	AccessToken string `json:"access_token" example:"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."`
	// JWT refresh token used to obtain new access tokens
	RefreshToken string `json:"refresh_token" example:"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."`
	// When the access token expires
	ExpiresAt time.Time `json:"expires_at" example:"2025-04-25T12:00:00Z"`
}

// AuthConfig contains authentication configuration.
// @Description Authentication and authorization configuration settings.
type AuthConfig struct {
	// Secret key used for signing JWT tokens
	JWTSecret string `json:"jwt_secret" example:"very-secret-key-do-not-share"`
	// How long JWT tokens are valid
	JWTExpiration time.Duration `json:"jwt_expiration" example:"24h"`
	// OAuth callback URL
	CallbackURL string `json:"callback_url" example:"https://api.example.com/auth/callback"`
	// Map of local usernames to password hashes
	LocalUsers map[string]string `json:"local_users"`
	// Configuration for SSO providers like Google, GitHub, etc.
	SSOProviders map[string]SSOConfig `json:"sso_providers"`
}

// SSOConfig contains configuration for a single SSO provider.
// @Description Configuration for a single Single Sign-On provider.
type SSOConfig struct {
	// OAuth client ID
	ClientID string `json:"client_id" example:"oauth-client-id"`
	// OAuth client secret
	ClientSecret string `json:"client_secret" example:"oauth-client-secret"`
	// OAuth scopes requested
	Scopes []string `json:"scopes" example:"profile,email"`
}
