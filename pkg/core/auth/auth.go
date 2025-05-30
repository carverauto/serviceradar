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

package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/markbates/goth"
	"github.com/markbates/goth/providers/github"
	"github.com/markbates/goth/providers/google"
	"golang.org/x/crypto/bcrypt"
)

var (
	errInvalidCreds = errors.New("invalid credentials")
)

const (
	defaultTimeout = 5 * time.Second
)

type Auth struct {
	config *models.AuthConfig
	db     db.Service
}

func NewAuth(config *models.AuthConfig, d db.Service) *Auth {
	// Initialize goth providers
	for provider, ssoConfig := range config.SSOProviders {
		switch provider {
		case "google":
			goth.UseProviders(
				google.New(ssoConfig.ClientID, ssoConfig.ClientSecret, config.CallbackURL+"/auth/"+provider+"/callback", ssoConfig.Scopes...),
			)
		case "github":
			goth.UseProviders(
				github.New(ssoConfig.ClientID, ssoConfig.ClientSecret, config.CallbackURL+"/auth/"+provider+"/callback", ssoConfig.Scopes...),
			)
		}
	}

	return &Auth{config: config, db: d}
}

func (a *Auth) LoginLocal(ctx context.Context, username, password string) (*models.Token, error) {
	storedHash, ok := a.config.LocalUsers[username]
	if !ok {
		return nil, db.ErrUserNotFound
	}

	if err := bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(password)); err != nil {
		return nil, errInvalidCreds
	}

	user := &models.User{
		ID:       generateUserID(username),
		Email:    username, // Or fetch from DB if we decide to store emails.
		Name:     username,
		Provider: "local",
	}

	return a.generateAndStoreToken(ctx, user)
}

const (
	defaultRandStringLength = 32
)

func (*Auth) BeginOAuth(_ context.Context, provider string) (string, error) {
	p, err := goth.GetProvider(provider)
	if err != nil {
		return "", fmt.Errorf("provider not supported: %w", err)
	}

	session, err := p.BeginAuth(randString(defaultRandStringLength))
	if err != nil {
		return "", fmt.Errorf("failed to begin auth: %w", err)
	}

	url, err := session.GetAuthURL()
	if err != nil {
		return "", fmt.Errorf("failed to get auth URL: %w", err)
	}

	return url, nil
}

func (a *Auth) CompleteOAuth(ctx context.Context, provider string, gothUser *goth.User) (*models.Token, error) {
	user := &models.User{
		ID:       gothUser.UserID,
		Email:    gothUser.Email,
		Name:     gothUser.Name,
		Provider: provider,
	}

	return a.generateAndStoreToken(ctx, user)
}

func (a *Auth) RefreshToken(ctx context.Context, refreshToken string) (*models.Token, error) {
	claims, err := ParseJWT(refreshToken, a.config.JWTSecret)
	if err != nil {
		return nil, fmt.Errorf("invalid refresh token: %w", err)
	}

	user := &models.User{
		ID:       claims.UserID,
		Email:    claims.Email,
		Provider: claims.Provider,
	}

	return a.generateAndStoreToken(ctx, user)
}

func (a *Auth) VerifyToken(_ context.Context, token string) (*models.User, error) {
	claims, err := ParseJWT(token, a.config.JWTSecret)
	if err != nil {
		return nil, fmt.Errorf("invalid token: %w", err)
	}

	return &models.User{
		ID:       claims.UserID,
		Email:    claims.Email,
		Provider: claims.Provider,
	}, nil
}

func (a *Auth) generateAndStoreToken(ctx context.Context, user *models.User) (*models.Token, error) {
	timeoutCtx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	token, err := GenerateTokenPair(user, a.config)
	if err != nil {
		return nil, fmt.Errorf("failed to generate token: %w", err)
	}

	// Store user if not exists
	err = a.db.StoreUser(timeoutCtx, user)
	if err != nil && !errors.Is(err, db.ErrUserNotFound) {
		return nil, fmt.Errorf("failed to store user: %w", err)
	}

	return token, nil
}

func generateUserID(username string) string {
	hash := sha256.Sum256([]byte(username))

	return base64.URLEncoding.EncodeToString(hash[:])
}

func randString(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)

	return base64.URLEncoding.EncodeToString(b)
}
