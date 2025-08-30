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

package api

import (
	"encoding/json"
	"net/http"

	"github.com/gorilla/mux"
	"github.com/markbates/goth"
	"github.com/markbates/goth/gothic"
)

// @Summary Authenticate with username and password
// @Description Logs in a user with username and password and returns authentication tokens
// @Tags Authentication
// @Accept json
// @Produce json
// @Param credentials body LoginCredentials true "User credentials"
// @Success 200 {object} models.Token "Authentication tokens"
// @Failure 400 {object} models.ErrorResponse "Invalid request"
// @Failure 401 {object} models.ErrorResponse "Authentication failed"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /auth/login [post]
func (s *APIServer) handleLocalLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}

	var creds LoginCredentials

	if err := json.NewDecoder(r.Body).Decode(&creds); err != nil {
		http.Error(w, "invalid request", http.StatusBadRequest)

		return
	}

	token, err := s.authService.LoginLocal(r.Context(), creds.Username, creds.Password)
	if err != nil {
		http.Error(w, "login failed: "+err.Error(), http.StatusUnauthorized)

		return
	}

	if err := s.encodeJSONResponse(w, token); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding login response")
		http.Error(w, "login failed", http.StatusInternalServerError)

		return
	}

	s.logger.Info().Str("username", creds.Username).Msg("Login response sent")
}

// LoginCredentials represents the credentials needed for local authentication.
type LoginCredentials struct {
	// Username for authentication
	Username string `json:"username" example:"admin"`
	// Password for authentication
	Password string `json:"password" example:"password123"`
}

// @Summary Begin OAuth authentication.
// @Description Initiates OAuth authentication flow with the specified provider.
// @Tags Authentication
// @Accept json
// @Produce json
// @Param provider path string true "OAuth provider (e.g., 'google', 'github')"
// @Success 302 {string} string "Redirect to OAuth provider"
// @Failure 400 {object} models.ErrorResponse "Invalid provider"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /auth/{provider} [get]
func (*APIServer) handleOAuthBegin(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)

	provider := vars["provider"]

	// Check if the provider is valid
	if _, err := goth.GetProvider(provider); err != nil {
		http.Error(w, "OAuth provider not supported", http.StatusBadRequest)

		return
	}

	// gothic.BeginAuthHandler handles the redirect and session setup
	gothic.BeginAuthHandler(w, r)
}

// @Summary Complete OAuth authentication.
// @Description Completes OAuth authentication flow and returns authentication tokens
// @Tags Authentication
// @Accept json
// @Produce json
// @Param provider path string true "OAuth provider (e.g., 'google', 'github')"
// @Success 200 {object} models.Token "Authentication tokens"
// @Failure 400 {object} models.ErrorResponse "Invalid request"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /auth/{provider}/callback [get]
func (s *APIServer) handleOAuthCallback(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)

	provider := vars["provider"]

	// Complete the OAuth flow using gothic
	gothUser, err := gothic.CompleteUserAuth(w, r)
	if err != nil {
		s.logger.Error().Err(err).Str("provider", provider).Msg("OAuth callback failed")
		http.Error(w, "OAuth callback failed: "+err.Error(), http.StatusInternalServerError)

		return
	}

	// Generate JWT token using your auth service
	token, err := s.authService.CompleteOAuth(r.Context(), provider, &gothUser)
	if err != nil {
		s.logger.Error().Err(err).Str("provider", provider).Msg("Token generation failed")
		http.Error(w, "Token generation failed", http.StatusInternalServerError)

		return
	}

	if err := s.encodeJSONResponse(w, token); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding token response")
		http.Error(w, "Token generation failed", http.StatusInternalServerError)

		return
	}
}

// RefreshTokenRequest represents the refresh token request
type RefreshTokenRequest struct {
	// Refresh token from previous authentication
	RefreshToken string `json:"refresh_token" example:"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."`
}

// @Summary Refresh authentication token
// @Description Refreshes an expired authentication token
// @Tags Authentication
// @Accept json
// @Produce json
// @Param refresh_token body RefreshTokenRequest true "Refresh token"
// @Success 200 {object} models.Token "New authentication tokens"
// @Failure 400 {object} models.ErrorResponse "Invalid request"
// @Failure 401 {object} models.ErrorResponse "Invalid refresh token"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /auth/refresh [post]
func (s *APIServer) handleRefreshToken(w http.ResponseWriter, r *http.Request) {
	var req RefreshTokenRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request", http.StatusBadRequest)

		return
	}

	token, err := s.authService.RefreshToken(r.Context(), req.RefreshToken)
	if err != nil {
		http.Error(w, "token refresh failed", http.StatusUnauthorized)

		return
	}

	err = s.encodeJSONResponse(w, token)
	if err != nil {
		s.logger.Error().Err(err).Msg("Error encoding refresh token response")
		http.Error(w, "token refresh failed", http.StatusInternalServerError)

		return
	}
}

// @Summary Get configuration
// @Description Retrieves configuration for a specific service
// @Tags Admin
// @Accept json
// @Produce json
// @Param service path string true "Service name (core, sync, poller, agent)"
// @Param kvStore query string false "KV store identifier (default: local)"
// @Success 200 {object} map[string]interface{} "Service configuration"
// @Failure 400 {object} models.ErrorResponse "Invalid service"
// @Failure 403 {object} models.ErrorResponse "Access denied"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/admin/config/{service} [get]
func (s *APIServer) handleGetConfig(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	service := vars["service"]

	// For now, return a placeholder response
	// TODO: Implement actual configuration retrieval from KV store
	user, _ := auth.GetUserFromContext(r.Context())
	config := map[string]interface{}{
		"service": service,
		"message": "Configuration retrieval not yet implemented",
		"user":    user,
	}

	if err := s.encodeJSONResponse(w, config); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding config response")
		http.Error(w, "Failed to retrieve configuration", http.StatusInternalServerError)
		return
	}
}

// @Summary Update configuration
// @Description Updates configuration for a specific service
// @Tags Admin
// @Accept json
// @Produce json
// @Param service path string true "Service name (core, sync, poller, agent)"
// @Param kvStore query string false "KV store identifier (default: local)"
// @Param config body map[string]interface{} true "Configuration object"
// @Success 200 {object} map[string]interface{} "Update result"
// @Failure 400 {object} models.ErrorResponse "Invalid request"
// @Failure 403 {object} models.ErrorResponse "Access denied"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/admin/config/{service} [put]
func (s *APIServer) handleUpdateConfig(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	service := vars["service"]

	var configData map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&configData); err != nil {
		http.Error(w, "Invalid configuration data", http.StatusBadRequest)
		return
	}

	// For now, return a placeholder response
	// TODO: Implement actual configuration update to KV store
	user, _ := auth.GetUserFromContext(r.Context())
	result := map[string]interface{}{
		"service": service,
		"message": "Configuration update not yet implemented",
		"received_config": configData,
		"user": user,
	}

	if err := s.encodeJSONResponse(w, result); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding config update response")
		http.Error(w, "Failed to update configuration", http.StatusInternalServerError)
		return
	}
}
