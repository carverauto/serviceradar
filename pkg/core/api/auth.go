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
	"log"
	"net/http"

	"github.com/gorilla/mux"
	"github.com/markbates/goth"
	"github.com/markbates/goth/gothic"
)

func (s *APIServer) handleLocalLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)

		return
	}

	var creds struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}

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
		log.Printf("Error encoding login response: %v", err)
		http.Error(w, "login failed", http.StatusInternalServerError)

		return
	}

	log.Printf("Login response sent for %s", creds.Username)
}

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

func (s *APIServer) handleOAuthCallback(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)

	provider := vars["provider"]

	// Complete the OAuth flow using gothic
	gothUser, err := gothic.CompleteUserAuth(w, r)
	if err != nil {
		log.Printf("OAuth callback failed for provider %s: %v", provider, err)
		http.Error(w, "OAuth callback failed: "+err.Error(), http.StatusInternalServerError)

		return
	}

	// Generate JWT token using your auth service
	token, err := s.authService.CompleteOAuth(r.Context(), provider, &gothUser)
	if err != nil {
		log.Printf("Token generation failed for provider %s: %v", provider, err)
		http.Error(w, "Token generation failed", http.StatusInternalServerError)

		return
	}

	if err := s.encodeJSONResponse(w, token); err != nil {
		log.Printf("Error encoding token response: %v", err)
		http.Error(w, "Token generation failed", http.StatusInternalServerError)

		return
	}
}

func (s *APIServer) handleRefreshToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}

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
		log.Println(err)
		http.Error(w, "token refresh failed", http.StatusInternalServerError)

		return
	}
}
