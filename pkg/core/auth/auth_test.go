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

// pkg/core/auth/auth_test.go
package auth

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/markbates/goth"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"golang.org/x/crypto/bcrypt"
)

func TestNewAuth(t *testing.T) {
	config := &models.AuthConfig{
		JWTSecret:     "test-secret",
		JWTExpiration: 24 * time.Hour,
		SSOProviders: map[string]models.SSOConfig{
			"google": {
				ClientID:     "test-client-id",
				ClientSecret: "test-secret",
				Scopes:       []string{"email"},
			},
		},
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	auth := NewAuth(config, mockDB)
	assert.NotNil(t, auth)
	assert.Equal(t, config, auth.config)
	assert.Equal(t, mockDB, auth.db)
}

func TestLoginLocal(t *testing.T) {
	tests := []struct {
		name           string
		username       string
		password       string
		configUsers    map[string]string
		dbError        error
		expectedError  bool
		expectedUserID string
	}{
		{
			name:     "successful login",
			username: "admin",
			password: "password123",
			configUsers: map[string]string{
				"admin": "", // We'll set this properly in the test
			},
			expectedUserID: generateUserID("admin"),
		},
		{
			name:     "invalid password",
			username: "admin",
			password: "wrongpass",
			configUsers: map[string]string{
				"admin": "", // We'll set this properly in the test
			},
			expectedError: true,
		},
		{
			name:          "user not found",
			username:      "unknown",
			password:      "password123",
			configUsers:   map[string]string{},
			expectedError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)

			// Generate a proper bcrypt hash for the password
			if len(tt.configUsers) > 0 {
				hash, err := bcrypt.GenerateFromPassword([]byte("password123"), bcrypt.DefaultCost)
				require.NoError(t, err)

				tt.configUsers["admin"] = string(hash)
			}

			config := &models.AuthConfig{
				JWTSecret:     "test-secret",
				JWTExpiration: time.Hour,
				LocalUsers:    tt.configUsers,
			}

			// Mock successful user storage only for successful case
			if !tt.expectedError && len(tt.configUsers) > 0 {
				mockDB.EXPECT().StoreUser(gomock.Any()).Return(nil)
			}

			a := NewAuth(config, mockDB)

			ctx := context.Background()
			token, err := a.LoginLocal(ctx, tt.username, tt.password)

			if tt.expectedError {
				require.Error(t, err)

				if tt.username == "unknown" {
					require.ErrorIs(t, err, db.ErrUserNotFound)
				} else {
					require.ErrorIs(t, err, errInvalidCreds)
				}

				assert.Nil(t, token)
			} else {
				require.NoError(t, err, "Login should succeed")
				assert.NotNil(t, token, "Token should not be nil")
				assert.NotEmpty(t, token.AccessToken, "Access token should not be empty")
				assert.NotEmpty(t, token.RefreshToken, "Refresh token should not be empty")

				// Verify token contents
				claims, err := ParseJWT(token.AccessToken, config.JWTSecret)
				require.NoError(t, err, "Token parsing should succeed")
				assert.Equal(t, tt.username, claims.Email, "Email should match username")
				assert.Equal(t, "local", claims.Provider, "Provider should be local")
			}
		})
	}
}

func TestBeginOAuth(t *testing.T) {
	config := &models.AuthConfig{
		JWTSecret:     "test-secret",
		JWTExpiration: time.Hour,
		CallbackURL:   "http://localhost:8080",
		SSOProviders: map[string]models.SSOConfig{
			"google": {
				ClientID:     "test-client-id",
				ClientSecret: "test-secret",
				Scopes:       []string{"email"},
			},
		},
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	a := NewAuth(config, mockDB)

	tests := []struct {
		name        string
		provider    string
		expectError bool
	}{
		{
			name:     "valid provider",
			provider: "google",
		},
		{
			name:        "invalid provider",
			provider:    "invalid",
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			url, err := a.BeginOAuth(context.Background(), tt.provider)

			if tt.expectError {
				require.Error(t, err)
				assert.Empty(t, url)
			} else {
				require.NoError(t, err)
				assert.NotEmpty(t, url)
				assert.Contains(t, url, "google")
			}
		})
	}
}

func TestCompleteOAuth(t *testing.T) {
	config := &models.AuthConfig{
		JWTSecret:     "test-secret",
		JWTExpiration: time.Hour,
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().StoreUser(gomock.Any()).Return(nil)

	a := NewAuth(config, mockDB)

	gothUser := goth.User{
		UserID:   "123",
		Email:    "test@example.com",
		Name:     "Test User",
		Provider: "google",
	}

	token, err := a.CompleteOAuth(context.Background(), "google", &gothUser)

	require.NoError(t, err)
	assert.NotNil(t, token)
	assert.NotEmpty(t, token.AccessToken)
	assert.NotEmpty(t, token.RefreshToken)

	claims, err := ParseJWT(token.AccessToken, config.JWTSecret)
	require.NoError(t, err)
	assert.Equal(t, "123", claims.UserID)
	assert.Equal(t, "test@example.com", claims.Email)
	assert.Equal(t, "google", claims.Provider)
}

func TestRefreshToken(t *testing.T) {
	config := &models.AuthConfig{
		JWTSecret:     "test-secret",
		JWTExpiration: time.Hour,
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().StoreUser(gomock.Any()).Return(nil).Times(1)

	a := NewAuth(config, mockDB)

	// Generate initial token
	user := &models.User{
		ID:       "123",
		Email:    "test@example.com",
		Provider: "test",
	}
	initialToken, err := GenerateTokenPair(user, config)
	require.NoError(t, err)

	// Test refresh
	newToken, err := a.RefreshToken(context.Background(), initialToken.RefreshToken)
	require.NoError(t, err, "Refresh should succeed")
	assert.NotNil(t, newToken, "New token should not be nil")
	assert.NotEmpty(t, newToken.AccessToken, "New access token should not be empty")
	assert.NotEmpty(t, newToken.RefreshToken, "New refresh token should not be empty")

	// Verify the new token is valid and preserves user data
	newClaims, err := ParseJWT(newToken.AccessToken, config.JWTSecret)
	require.NoError(t, err, "Should parse new token")
	assert.Equal(t, user.ID, newClaims.UserID, "UserID should be preserved")
	assert.Equal(t, user.Email, newClaims.Email, "Email should be preserved")
	assert.Equal(t, user.Provider, newClaims.Provider, "Provider should be preserved")

	// Verify expiration is in the future
	assert.True(t, newClaims.ExpiresAt.After(time.Now()),
		"New token expiration should be in the future, got: %v", newClaims.ExpiresAt.Time)

	// Verify it's not expired yet
	assert.True(t, newClaims.ExpiresAt.After(newClaims.IssuedAt.Time),
		"Expiration should be after issuance, IssuedAt: %v, ExpiresAt: %v",
		newClaims.IssuedAt.Time, newClaims.ExpiresAt.Time)
}

func TestVerifyToken(t *testing.T) {
	config := &models.AuthConfig{
		JWTSecret:     "test-secret",
		JWTExpiration: time.Hour,
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	a := NewAuth(config, mockDB)

	user := &models.User{
		ID:       "123",
		Email:    "test@example.com",
		Provider: "test",
	}
	tokenPair, err := GenerateTokenPair(user, config)
	require.NoError(t, err)

	verifiedUser, err := a.VerifyToken(context.Background(), tokenPair.AccessToken)
	require.NoError(t, err)
	assert.NotNil(t, verifiedUser)
	assert.Equal(t, user.ID, verifiedUser.ID)
	assert.Equal(t, user.Email, verifiedUser.Email)
	assert.Equal(t, user.Provider, verifiedUser.Provider)

	// Test invalid token
	_, err = a.VerifyToken(context.Background(), "invalid.token.here")
	assert.Error(t, err)
}
