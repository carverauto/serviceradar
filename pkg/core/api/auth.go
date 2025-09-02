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
    "fmt"
    "net/http"
    "strings"
    "io"

    "github.com/carverauto/serviceradar/pkg/core/auth"
    "github.com/gorilla/mux"
    "github.com/markbates/goth"
    "github.com/markbates/goth/gothic"
    "github.com/carverauto/serviceradar/proto"
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

    // Try to read current config from KV if a key is provided or can be derived
    key := r.URL.Query().Get("key")
    agentID := r.URL.Query().Get("agent_id")
    serviceType := r.URL.Query().Get("service_type")
    kvStoreID := r.URL.Query().Get("kv_store_id")
    if kvStoreID == "" { kvStoreID = r.URL.Query().Get("kvStore") }

    if key == "" {
        if k, ok := defaultKVKeyForService(service, serviceType, agentID); ok {
            key = k
        } else if k, ok := serviceLevelKeyFor(service); ok {
            key = k
        }
    }

    if key != "" {
        // Prefix key with domain for leaf KVs when provided (domains/<kv_store_id>/key)
        if kvStoreID != "" && !strings.HasPrefix(key, "domains/") {
            domain := s.resolveKVDomain(kvStoreID)
            if domain != "" { key = fmt.Sprintf("domains/%s/%s", domain, key) }
        }
        // Prefer per-request KV store selection if provided
        if kvStoreID != "" {
            if kvClient, closeFn, err := s.getKVClient(r.Context(), kvStoreID); err == nil {
                defer closeFn()
                if resp, err := kvClient.Get(r.Context(), &proto.GetRequest{ Key: key }); err == nil {
                    if resp.Found {
                        if strings.HasSuffix(strings.ToLower(key), ".toml") {
                            w.Header().Set("Content-Type", "text/plain; charset=utf-8")
                            _, _ = w.Write(resp.Value)
                        } else {
                            w.Header().Set("Content-Type", "application/json")
                            _, _ = w.Write(resp.Value)
                        }
                        return
                    }
                    http.Error(w, "configuration not found", http.StatusNotFound)
                    return
                }
            }
            // Fall through to default KV if specific dial failed
        }
        if s.kvGetFn != nil {
            if data, found, err := s.kvGetFn(r.Context(), key); err == nil {
                if found {
                    if strings.HasSuffix(strings.ToLower(key), ".toml") {
                        w.Header().Set("Content-Type", "text/plain; charset=utf-8")
                        _, _ = w.Write(data)
                    } else {
                        w.Header().Set("Content-Type", "application/json")
                        _, _ = w.Write(data)
                    }
                    return
                }
                http.Error(w, "configuration not found", http.StatusNotFound)
                return
            } else {
                s.logger.Warn().Err(err).Str("key", key).Msg("KV Get failed; falling back to defaults")
            }
        }
    }

    // Fallback to default configuration based on service type
    config := s.getDefaultServiceConfig(service)
    if config == nil {
        http.Error(w, "Unknown service type", http.StatusBadRequest)
        return
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

    // Basic validation that the service type is known
    if s.getDefaultServiceConfig(service) == nil && service != "otel" && service != "flowgger" {
        http.Error(w, "Unknown service type", http.StatusBadRequest)
        return
    }

    // Preferred: explicit KV key via ?key=. Otherwise derive from service_type and agent_id
    key := r.URL.Query().Get("key")
    agentID := r.URL.Query().Get("agent_id")
    serviceType := r.URL.Query().Get("service_type")
    kvStoreID := r.URL.Query().Get("kv_store_id")
    if kvStoreID == "" { kvStoreID = r.URL.Query().Get("kvStore") }

    var configBytes []byte
    var err error

    if key == "" {
        if k, ok := defaultKVKeyForService(service, serviceType, agentID); ok {
            key = k
        } else if k, ok := serviceLevelKeyFor(service); ok {
            key = k
        } else {
            http.Error(w, "key is required for this service (no default path)", http.StatusBadRequest)
            return
        }
    }

    // Determine payload handling based on target key/file type
    if strings.HasSuffix(strings.ToLower(key), ".toml") || strings.Contains(r.Header.Get("Content-Type"), "text/plain") {
        // Read raw body for TOML/text
        raw, readErr := io.ReadAll(r.Body)
        if readErr != nil {
            http.Error(w, "Failed to read request body", http.StatusBadRequest)
            return
        }
        configBytes = raw
    } else {
        // JSON body: decode/gently re-encode to ensure compact form
        var configData map[string]interface{}
        if decodeErr := json.NewDecoder(r.Body).Decode(&configData); decodeErr != nil {
            http.Error(w, "Invalid configuration data", http.StatusBadRequest)
            return
        }
        configBytes, err = json.Marshal(configData)
        if err != nil {
            http.Error(w, "Failed to encode configuration", http.StatusBadRequest)
            return
        }
    }

    // Prefix key with domain for leaf KVs when provided (domains/<kv_store_id>/key)
    if kvStoreID != "" && !strings.HasPrefix(key, "domains/") {
        domain := s.resolveKVDomain(kvStoreID)
        if domain != "" { key = fmt.Sprintf("domains/%s/%s", domain, key) }
    }

    // Prefer per-request KV if provided
    if kvStoreID != "" {
        kvClient, closeFn, err := s.getKVClient(r.Context(), kvStoreID)
        if err == nil {
            defer closeFn()
            if _, err := kvClient.Put(r.Context(), &proto.PutRequest{ Key: key, Value: configBytes, TtlSeconds: 0 }); err != nil {
                s.logger.Error().Err(err).Str("key", key).Str("kv_store_id", kvStoreID).Msg("KV Put failed")
                http.Error(w, "Failed to write configuration to KV", http.StatusInternalServerError)
                return
            }
        } else {
            s.logger.Warn().Err(err).Str("kv_store_id", kvStoreID).Msg("KV dial failed; falling back to default KV")
        }
    }
    if kvStoreID == "" {
        if s.kvPutFn == nil {
            http.Error(w, "KV client not initialized", http.StatusInternalServerError)
            return
        }
        if err := s.kvPutFn(r.Context(), key, configBytes, 0); err != nil {
            s.logger.Error().Err(err).Str("key", key).Msg("KV Put failed")
            http.Error(w, "Failed to write configuration to KV", http.StatusInternalServerError)
            return
        }
    }

    user, _ := auth.GetUserFromContext(r.Context())
    userEmail := ""
    if user != nil { userEmail = user.Email }
    result := map[string]interface{}{
        "service":      service,
        "service_type": serviceType,
        "kv_store_id":  kvStoreID,
        "key":          key,
        "status":       "updated",
        "bytes":        len(configBytes),
        "user":         userEmail,
    }

    if err := s.encodeJSONResponse(w, result); err != nil {
        s.logger.Error().Err(err).Msg("Error encoding config update response")
        http.Error(w, "Failed to update configuration", http.StatusInternalServerError)
        return
    }
}

// defaultKVKeyForService returns a conventional KV key for known services.
// Returns (key, true) if a default exists, otherwise ("", false).
func defaultKVKeyForService(service, serviceType, agentID string) (string, bool) {
    if service == "sweep" || serviceType == "sweep" {
        if agentID == "" { return "", false }
        return fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", agentID), true
    }
    if service == "snmp" || serviceType == "snmp" || service == "snmp-checker" {
        if agentID == "" { return "", false }
        return fmt.Sprintf("agents/%s/checkers/snmp/snmp.json", agentID), true
    }
    if service == "mapper" || serviceType == "mapper" || service == "serviceradar-mapper" {
        if agentID == "" { return "", false }
        return fmt.Sprintf("agents/%s/checkers/mapper/mapper.json", agentID), true
    }
    if service == "trapd" || serviceType == "trapd" || service == "serviceradar-trapd" {
        if agentID == "" { return "", false }
        return fmt.Sprintf("agents/%s/checkers/trapd/trapd.json", agentID), true
    }
    if service == "rperf" || serviceType == "rperf" || service == "rperf-checker" {
        if agentID == "" { return "", false }
        return fmt.Sprintf("agents/%s/checkers/rperf/rperf.json", agentID), true
    }
    if service == "sysmon" || serviceType == "sysmon" {
        if agentID == "" { return "", false }
        return fmt.Sprintf("agents/%s/checkers/sysmon/sysmon.json", agentID), true
    }
    return "", false
}

// serviceLevelKeyFor returns a KV key for service-level configuration managed via pkg/config.
func serviceLevelKeyFor(service string) (string, bool) {
    switch service {
    case "flowgger":
        return "config/flowgger.toml", true
    case "otel":
        return "config/otel.toml", true
    case "trapd":
        return "config/trapd.json", true
    case "core", "sync", "poller", "agent", "db-event-writer":
        return fmt.Sprintf("config/%s.json", service), true
    default:
        return "", false
    }
}

// getDefaultServiceConfig returns default configuration templates for different services
func (s *APIServer) getDefaultServiceConfig(serviceType string) map[string]interface{} {
    switch serviceType {
	case "core":
		return map[string]interface{}{
			"listen_addr":      ":8090",
			"grpc_addr":       ":50052", 
			"alert_threshold": "5m",
			"known_pollers":   []string{"default-poller"},
			"metrics": map[string]interface{}{
				"enabled":     true,
				"retention":   100,
				"max_pollers": 10000,
			},
			"database": map[string]interface{}{
				"addresses":  []string{"proton:9440"},
				"name":       "default",
				"username":   "default",
				"password":   "",
				"max_conns":  10,
				"idle_conns": 5,
			},
			"nats": map[string]interface{}{
				"url": "nats://127.0.0.1:4222",
			},
			"auth": map[string]interface{}{
				"jwt_secret":     "",
				"jwt_expiration": "24h",
				"local_users": map[string]string{
					"admin": "",
				},
			},
		}
	case "sync":
		return map[string]interface{}{
			"listen_addr": ":8091",
			"database": map[string]interface{}{
				"addresses":  []string{"proton:9440"},
				"name":       "default", 
				"username":   "default",
				"password":   "",
				"max_conns":  10,
				"idle_conns": 5,
			},
			"nats": map[string]interface{}{
				"url": "nats://127.0.0.1:4222",
			},
		}
	case "poller":
		return map[string]interface{}{
			"listen_addr": ":8092",
			"scan": map[string]interface{}{
				"subnet":   "192.168.1.0/24",
				"timeout":  "5s",
				"interval": "30s",
			},
			"nats": map[string]interface{}{
				"url": "nats://127.0.0.1:4222",
			},
		}
    case "agent":
        return map[string]interface{}{
            "listen_addr": ":8093",
            "collection": map[string]interface{}{
                "interval": "10s",
                "timeout":  "5s",
            },
            "nats": map[string]interface{}{
                "url": "nats://127.0.0.1:4222",
            },
        }
    case "sweep":
        return map[string]interface{}{
            "networks": []string{},
            "interval": "60s",
            "timeout":  "5s",
        }
    case "snmp":
        return map[string]interface{}{
            "enabled":      false,
            "listen_addr":  ":50043",
            "node_address": "localhost:50043",
            "partition":    "default",
            "targets":      []map[string]interface{}{},
        }
    case "mapper":
        return map[string]interface{}{
            "enabled": true,
            "address": "serviceradar-mapper:50056",
        }
    case "trapd":
        return map[string]interface{}{
            "enabled":     false,
            "listen_addr": ":50043",
        }
    case "rperf":
        return map[string]interface{}{
            "enabled": false,
            "targets": []map[string]interface{}{},
        }
    case "sysmon":
        return map[string]interface{}{
            "enabled":  true,
            "interval": "10s",
        }
    default:
        return nil
    }
}
