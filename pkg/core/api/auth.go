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
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/gorilla/mux"
	"github.com/markbates/goth"
	"github.com/markbates/goth/gothic"
)

// Service name constants
const (
	serviceSweep  = "sweep"
	serviceSNMP   = "snmp"
	serviceMapper = "mapper"
	serviceTrapd  = "trapd"
	serviceRPerf  = "rperf"
	serviceSysmon = "sysmon"
	serviceAgent  = "agent"
)

var (
	errTemplateUnavailable = errors.New("config template unavailable")
	errKVKeyNotSpecified   = errors.New("kv key not specified")
	errKVPutUnavailable    = fmt.Errorf("kv put unavailable")
	errConfigKeyUnresolved = fmt.Errorf("configuration key could not be determined")
)

const (
	configOriginSeeded  = "seeded"
	configOriginUser    = "user"
	configOriginUnknown = "unknown"
)

type configStatusEntry struct {
	Name        string              `json:"name"`
	ServiceType string              `json:"service_type"`
	Scope       string              `json:"scope"`
	KVKey       string              `json:"kv_key"`
	KVStoreID   string              `json:"kv_store_id,omitempty"`
	Format      config.ConfigFormat `json:"format"`
	Found       bool                `json:"found"`
	Error       string              `json:"error,omitempty"`
}

type configStatusResponse struct {
	Status       string              `json:"status"`
	KVStoreID    string              `json:"kv_store_id,omitempty"`
	MissingCount int                 `json:"missing_count"`
	ErrorCount   int                 `json:"error_count"`
	FirstMissing *configStatusEntry  `json:"first_missing,omitempty"`
	Entries      []configStatusEntry `json:"entries"`
}

type configMetadataRecord struct {
	Origin    string    `json:"origin"`
	Writer    string    `json:"writer,omitempty"`
	UpdatedAt time.Time `json:"updated_at,omitempty"`
}

type configMetadata struct {
	Service    string              `json:"service"`
	KVKey      string              `json:"kv_key"`
	KVStoreID  string              `json:"kv_store_id,omitempty"`
	Revision   uint64              `json:"revision"`
	Origin     string              `json:"origin,omitempty"`
	LastWriter string              `json:"last_writer,omitempty"`
	UpdatedAt  *time.Time          `json:"updated_at,omitempty"`
	Format     config.ConfigFormat `json:"format"`
}

type configResponse struct {
	Metadata  configMetadata  `json:"metadata"`
	Config    json.RawMessage `json:"config,omitempty"`
	RawConfig string          `json:"raw_config,omitempty"`
}

type configDescriptorResponse struct {
	Name          string `json:"name"`
	DisplayName   string `json:"display_name,omitempty"`
	ServiceType   string `json:"service_type"`
	Scope         string `json:"scope"`
	KVKey         string `json:"kv_key,omitempty"`
	KVKeyTemplate string `json:"kv_key_template,omitempty"`
	Format        string `json:"format"`
	RequiresAgent bool   `json:"requires_agent"`
	RequiresPoller bool  `json:"requires_poller"`
}

// @Summary List managed config descriptors
// @Description Returns metadata about known service configurations
// @Tags Admin
// @Produce json
// @Success 200 {array} map[string]string
// @Router /api/admin/config [get]
func (s *APIServer) handleListConfigDescriptors(w http.ResponseWriter, r *http.Request) {
	descs := config.ServiceDescriptors()
	resp := make([]configDescriptorResponse, 0, len(descs))
	for _, desc := range descs {
		resp = append(resp, configDescriptorResponse{
			Name:          desc.Name,
			DisplayName:   desc.DisplayName,
			ServiceType:   desc.ServiceType,
			Scope:         string(desc.Scope),
			KVKey:         desc.KVKey,
			KVKeyTemplate: desc.KVKeyTemplate,
			Format:        string(desc.Format),
			RequiresAgent: desc.Scope == config.ConfigScopeAgent && desc.KVKeyTemplate != "",
			RequiresPoller: desc.Scope == config.ConfigScopePoller && desc.KVKeyTemplate != "",
		})
	}

	if err := s.encodeJSONResponse(w, resp); err != nil {
		s.logger.Error().Err(err).Msg("error encoding config descriptor response")
		s.writeAPIError(w, http.StatusInternalServerError, "failed to enumerate configurations")
	}
}

// @Summary Configuration coverage status
// @Description Checks whether every known descriptor has an initialized KV entry
// @Tags Admin
// @Produce json
// @Param kvStore query string false "Optional KV store identifier (defaults to local hub store)"
// @Success 200 {object} configStatusResponse "All descriptors have KV entries"
// @Failure 503 {object} configStatusResponse "One or more descriptors missing KV entries"
// @Failure 502 {object} configStatusResponse "KV lookups failed"
// @Router /api/admin/config/status [get]
func (s *APIServer) handleConfigStatus(w http.ResponseWriter, r *http.Request) {
	if s == nil {
		http.Error(w, "server not initialized", http.StatusInternalServerError)
		return
	}

	kvStoreID := r.URL.Query().Get("kv_store_id")
	if kvStoreID == "" {
		kvStoreID = r.URL.Query().Get("kvStore")
	}

	descs := config.ServiceDescriptors()
	resp := configStatusResponse{
		Status:    "ok",
		KVStoreID: kvStoreID,
		Entries:   make([]configStatusEntry, 0, len(descs)),
	}

	var firstMissing *configStatusEntry

	for _, desc := range descs {
		if desc.Scope != config.ConfigScopeGlobal || desc.KVKey == "" {
			continue
		}
		entry := configStatusEntry{
			Name:        desc.Name,
			ServiceType: desc.ServiceType,
			Scope:       string(desc.Scope),
			KVKey:       desc.KVKey,
			KVStoreID:   kvStoreID,
			Format:      desc.Format,
		}

		found, err := s.checkConfigKey(r.Context(), kvStoreID, desc.KVKey)
		entry.Found = err == nil && found

		switch {
		case err != nil:
			entry.Error = err.Error()
			resp.ErrorCount++
		case !found:
			resp.MissingCount++
			if firstMissing == nil {
				copyEntry := entry
				firstMissing = &copyEntry
			}
		}

		resp.Entries = append(resp.Entries, entry)
	}

	resp.FirstMissing = firstMissing

	statusCode := http.StatusOK
	switch {
	case resp.ErrorCount > 0:
		resp.Status = "error"
		statusCode = http.StatusBadGateway
	case resp.MissingCount > 0:
		resp.Status = "missing"
		statusCode = http.StatusServiceUnavailable
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		if s != nil && s.logger != nil {
			s.logger.Error().Err(err).Msg("error encoding config status response")
		}
	}
}

// @Summary List active KV watchers
// @Description Returns metadata about KV watchers running in this process
// @Tags Admin
// @Produce json
// @Param service query string false "Filter by descriptor/service name"
// @Success 200 {array} config.WatcherInfo
// @Router /api/admin/config/watchers [get]
func (s *APIServer) handleConfigWatchers(w http.ResponseWriter, r *http.Request) {
	filter := strings.TrimSpace(r.URL.Query().Get("service"))
	kvStoreID := r.URL.Query().Get("kv_store_id")
	if kvStoreID == "" {
		kvStoreID = r.URL.Query().Get("kvStore")
	}

	ctx := r.Context()
	var infos []config.WatcherInfo
	if kvStoreID == "" {
		infos = config.ListWatchers()
	}
	infos = append(infos, s.collectRemoteWatchers(ctx, kvStoreID)...)
	infos = s.filterAndDedupeWatchers(infos, filter)

	if err := s.encodeJSONResponse(w, infos); err != nil {
		s.logger.Error().Err(err).Msg("failed to encode watcher response")
		s.writeAPIError(w, http.StatusInternalServerError, "failed to enumerate watchers")
	}
}

type remoteWatcherTarget struct {
	service    string
	instanceID string
}

func (s *APIServer) collectRemoteWatchers(ctx context.Context, kvStoreID string) []config.WatcherInfo {
	targets := s.remoteWatcherTargets(ctx)
	snapshots := make([]config.WatcherInfo, 0, len(targets))
	for _, target := range targets {
		snapshot, err := s.loadWatcherSnapshot(ctx, kvStoreID, target.service, target.instanceID)
		if err != nil {
			if s.logger != nil {
				s.logger.Debug().
					Err(err).
					Str("service", target.service).
					Str("instance_id", target.instanceID).
					Msg("failed to load watcher snapshot")
			}
			continue
		}
		if snapshot != nil {
			snapshots = append(snapshots, *snapshot)
		}
	}
	return snapshots
}

func (s *APIServer) remoteWatcherTargets(ctx context.Context) []remoteWatcherTarget {
	descs := config.ServiceDescriptors()
	agentDescriptors := make([]config.ServiceDescriptor, 0)
	targets := make([]remoteWatcherTarget, 0, len(descs))

	for _, desc := range descs {
		if desc.Scope == config.ConfigScopeAgent {
			agentDescriptors = append(agentDescriptors, desc)
			continue
		}
		if desc.Scope == config.ConfigScopeGlobal {
			// Core watchers already exposed locally.
			if desc.Name == "core" {
				continue
			}
			targets = append(targets, remoteWatcherTarget{
				service:    desc.Name,
				instanceID: desc.Name,
			})
		}
	}

	if s.dbService != nil {
		if pollerIDs, err := s.dbService.ListPollers(ctx); err == nil {
			for _, pollerID := range pollerIDs {
				if pollerID == "" {
					continue
				}
				targets = append(targets, remoteWatcherTarget{
					service:    "poller",
					instanceID: pollerID,
				})
			}
		}

		if agents, err := s.dbService.ListAgentsWithPollers(ctx); err == nil {
			for _, agent := range agents {
				if agent.AgentID == "" {
					continue
				}
				targets = append(targets, remoteWatcherTarget{
					service:    "agent",
					instanceID: agent.AgentID,
				})
				for _, desc := range agentDescriptors {
					targets = append(targets, remoteWatcherTarget{
						service:    desc.Name,
						instanceID: agent.AgentID,
					})
				}
			}
		}
	}

	return targets
}

func (s *APIServer) loadWatcherSnapshot(ctx context.Context, kvStoreID, service, instanceID string) (*config.WatcherInfo, error) {
	if service == "" {
		return nil, nil
	}
	key, err := config.WatcherSnapshotKey(service, instanceID)
	if err != nil {
		return nil, err
	}
	resolvedKey := s.qualifyKVKey(kvStoreID, key)
	entry, err := s.getKVEntry(ctx, kvStoreID, resolvedKey)
	if err != nil || entry == nil || !entry.Found || len(entry.Value) == 0 {
		return nil, err
	}

	var snapshot config.WatcherSnapshot
	if err := json.Unmarshal(entry.Value, &snapshot); err != nil {
		return nil, err
	}

	return &snapshot.WatcherInfo, nil
}

func (s *APIServer) filterAndDedupeWatchers(infos []config.WatcherInfo, filter string) []config.WatcherInfo {
	dedup := make(map[string]config.WatcherInfo, len(infos))
	for _, info := range infos {
		key := fmt.Sprintf("%s|%s|%s",
			strings.ToLower(info.Service),
			strings.ToLower(info.InstanceID),
			strings.ToLower(info.KVKey),
		)
		if existing, ok := dedup[key]; ok {
			if info.LastEvent.After(existing.LastEvent) {
				dedup[key] = info
			}
			continue
		}
		dedup[key] = info
	}

	result := make([]config.WatcherInfo, 0, len(dedup))
	match := strings.ToLower(filter)
	for _, info := range dedup {
		if match != "" && !strings.EqualFold(info.Service, match) {
			continue
		}
		result = append(result, info)
	}

	sort.Slice(result, func(i, j int) bool {
		if result[i].Service == result[j].Service {
			if result[i].InstanceID == result[j].InstanceID {
				return result[i].KVKey < result[j].KVKey
			}
			return result[i].InstanceID < result[j].InstanceID
		}
		return result[i].Service < result[j].Service
	})

	return result
}

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
	ctx := r.Context()
	vars := mux.Vars(r)
	service := vars["service"]

	key := r.URL.Query().Get("key")
	agentID := r.URL.Query().Get("agent_id")
	pollerID := r.URL.Query().Get("poller_id")
	serviceType := r.URL.Query().Get("service_type")
	kvStoreID := r.URL.Query().Get("kv_store_id")
	if kvStoreID == "" {
		kvStoreID = r.URL.Query().Get("kvStore")
	}

	var desc config.ServiceDescriptor
	var hasDescriptor bool
	if key == "" {
		var err error
		desc, key, hasDescriptor, err = s.resolveServiceKey(service, serviceType, agentID, pollerID)
		if err != nil {
			s.writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
	} else {
		desc, hasDescriptor = s.lookupServiceDescriptor(service, serviceType, agentID, pollerID)
	}

	rawMode := isRawConfigRequested(r)
	baseKey := key
	resolvedKey := s.qualifyKVKey(kvStoreID, key)

	formatHint := guessFormatFromKey(resolvedKey)
	if hasDescriptor {
		formatHint = desc.Format
	}

	entry, metaRecord, err := s.loadConfigEntry(ctx, kvStoreID, resolvedKey)
	if err != nil && kvStoreID != "" {
		s.logger.Warn().Err(err).Str("key", resolvedKey).Str("kv_store_id", kvStoreID).Msg("KV fetch failed; falling back to default store")
		kvStoreID = ""
		resolvedKey = baseKey
		entry, metaRecord, err = s.loadConfigEntry(ctx, kvStoreID, resolvedKey)
	}
	if err != nil {
		s.logger.Error().Err(err).Str("key", resolvedKey).Msg("failed to load configuration")
		s.writeAPIError(w, http.StatusInternalServerError, "failed to load configuration")
		return
	}

	if kvEntryMissing(entry) {
		if !hasDescriptor {
			s.writeAPIError(w, http.StatusNotFound, "configuration not found")
			return
		}
		if _, seedErr := s.seedConfigFromTemplate(ctx, desc, resolvedKey, kvStoreID); seedErr == nil {
			entry, metaRecord, err = s.loadConfigEntry(ctx, kvStoreID, resolvedKey)
			if err != nil {
				s.logger.Error().Err(err).Str("key", resolvedKey).Msg("failed to reload seeded configuration")
				s.writeAPIError(w, http.StatusInternalServerError, "failed to load configuration")
				return
			}
		} else if !errors.Is(seedErr, errTemplateUnavailable) {
			s.logger.Warn().Err(seedErr).Str("service", desc.Name).Str("key", resolvedKey).Msg("failed to seed config template")
			s.writeAPIError(w, http.StatusInternalServerError, "failed to seed configuration template")
			return
		} else {
			s.logger.Warn().Str("service", desc.Name).Str("key", resolvedKey).Msg("no template available for seeding")
			s.writeAPIError(w, http.StatusNotFound, "configuration not found (template unavailable)")
			return
		}
	}

	if kvEntryMissing(entry) {
		s.writeAPIError(w, http.StatusNotFound, "configuration not found or empty")
		return
	}

	serviceName := service
	if hasDescriptor {
		serviceName = desc.Name
	}

	metadata := buildConfigMetadata(serviceName, kvStoreID, resolvedKey, formatHint, entry.Revision, metaRecord)

	if rawMode {
		s.writeRawConfigResponse(w, entry.Value, formatHint, metadata)
		return
	}

	resp := configResponse{
		Metadata: *metadata,
	}
	switch {
	case formatHint == config.ConfigFormatTOML:
		resp.RawConfig = string(entry.Value)
	case len(entry.Value) > 0:
		resp.Config = json.RawMessage(entry.Value)
	default:
		resp.Config = json.RawMessage([]byte("null"))
	}

	if err := s.encodeJSONResponse(w, resp); err != nil {
		s.logger.Error().Err(err).Msg("error encoding configuration response")
		s.writeAPIError(w, http.StatusInternalServerError, "failed to encode configuration")
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

	// Do not rely on hard-coded defaults; accept any service and require a concrete key

	// Preferred: explicit KV key via ?key=. Otherwise derive from service_type and agent_id
	key := r.URL.Query().Get("key")
	agentID := r.URL.Query().Get("agent_id")
	pollerID := r.URL.Query().Get("poller_id")
	serviceType := r.URL.Query().Get("service_type")
	kvStoreID := r.URL.Query().Get("kv_store_id")
	if kvStoreID == "" {
		kvStoreID = r.URL.Query().Get("kvStore")
	}

	var configBytes []byte
	var err error

	if key == "" {
		var err error
		_, key, _, err = s.resolveServiceKey(service, serviceType, agentID, pollerID)
		if err != nil {
			s.writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
	}
	if key == "" {
		s.writeAPIError(w, http.StatusBadRequest, "key is required for this service (no default path)")
		return
	}

	// Determine payload handling based on target key/file type
	if strings.HasSuffix(strings.ToLower(key), ".toml") || strings.Contains(r.Header.Get("Content-Type"), "text/plain") {
		// Read raw body for TOML/text
		raw, readErr := io.ReadAll(r.Body)
		if readErr != nil {
			s.writeAPIError(w, http.StatusBadRequest, "failed to read request body")
			return
		}
		configBytes = raw
	} else {
		// JSON body: decode/gently re-encode to ensure compact form
		var configData map[string]interface{}
		if decodeErr := json.NewDecoder(r.Body).Decode(&configData); decodeErr != nil {
			s.writeAPIError(w, http.StatusBadRequest, "invalid configuration data")
			return
		}
		configBytes, err = json.Marshal(configData)
		if err != nil {
			s.writeAPIError(w, http.StatusBadRequest, "failed to encode configuration")
			return
		}
	}

	key = s.qualifyKVKey(kvStoreID, key)

	// Prefer per-request KV if provided
	if kvStoreID != "" {
		kvClient, closeFn, err := s.getKVClient(r.Context(), kvStoreID)
		if err == nil {
			defer closeFn()
			if _, err := kvClient.Put(r.Context(), &proto.PutRequest{Key: key, Value: configBytes, TtlSeconds: 0}); err != nil {
				s.logger.Error().Err(err).Str("key", key).Str("kv_store_id", kvStoreID).Msg("KV Put failed")
				s.writeAPIError(w, http.StatusInternalServerError, "failed to write configuration to KV")
				return
			}
		} else {
			s.logger.Warn().Err(err).Str("kv_store_id", kvStoreID).Msg("KV dial failed; falling back to default KV")
		}
	}
	if kvStoreID == "" {
		if s.kvPutFn == nil {
			s.writeAPIError(w, http.StatusInternalServerError, "KV client not initialized")
			return
		}
		if err := s.kvPutFn(r.Context(), key, configBytes, 0); err != nil {
			s.logger.Error().Err(err).Str("key", key).Msg("KV Put failed")
			s.writeAPIError(w, http.StatusInternalServerError, "failed to write configuration to KV")
			return
		}
	}

	user, _ := auth.GetUserFromContext(r.Context())
	userEmail := ""
	if user != nil {
		userEmail = user.Email
	}

	s.recordConfigMetadata(r.Context(), kvStoreID, key, configOriginUser, userEmail)

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
		s.writeAPIError(w, http.StatusInternalServerError, "failed to update configuration")
		return
	}
}

func guessFormatFromKey(key string) config.ConfigFormat {
	if strings.HasSuffix(strings.ToLower(key), ".toml") {
		return config.ConfigFormatTOML
	}
	return config.ConfigFormatJSON
}

func (s *APIServer) writeRawConfigResponse(w http.ResponseWriter, data []byte, format config.ConfigFormat, meta *configMetadata) {
	if meta != nil {
		w.Header().Set("X-Serviceradar-Kv-Key", meta.KVKey)
		if meta.KVStoreID != "" {
			w.Header().Set("X-Serviceradar-Kv-Store", meta.KVStoreID)
		}
		if meta.Revision != 0 {
			w.Header().Set("X-Serviceradar-Kv-Revision", fmt.Sprintf("%d", meta.Revision))
		}
		if meta.Origin != "" {
			w.Header().Set("X-Serviceradar-Config-Origin", meta.Origin)
		}
		if meta.LastWriter != "" {
			w.Header().Set("X-Serviceradar-Config-Writer", meta.LastWriter)
		}
		if meta.UpdatedAt != nil {
			w.Header().Set("X-Serviceradar-Config-Updated-At", meta.UpdatedAt.Format(time.RFC3339))
		}
	}

	switch format {
	case config.ConfigFormatTOML:
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	case config.ConfigFormatJSON:
		w.Header().Set("Content-Type", "application/json")
	default:
		w.Header().Set("Content-Type", "application/json")
	}
	_, _ = w.Write(data)
}

func (s *APIServer) writeAPIError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	errResp := models.ErrorResponse{
		Message: message,
		Status:  status,
	}
	if err := json.NewEncoder(w).Encode(errResp); err != nil && s != nil && s.logger != nil {
		s.logger.Warn().Err(err).Msg("failed to encode error response")
	}
}

type kvEntry struct {
	Value    []byte
	Found    bool
	Revision uint64
}

func kvEntryMissing(entry *kvEntry) bool {
	return entry == nil || !entry.Found || len(entry.Value) == 0
}

func isRawConfigRequested(r *http.Request) bool {
	raw := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("raw")))
	if raw == "" {
		raw = strings.ToLower(strings.TrimSpace(r.URL.Query().Get("format")))
	}
	return raw == "1" || raw == authEnabledTrue || raw == "raw"
}

func (s *APIServer) loadConfigEntry(ctx context.Context, kvStoreID, key string) (*kvEntry, *configMetadataRecord, error) {
	entry, err := s.getKVEntry(ctx, kvStoreID, key)
	if err != nil {
		return nil, nil, err
	}
	if entry == nil || !entry.Found {
		return entry, nil, nil
	}

	meta, err := s.loadMetadataRecord(ctx, kvStoreID, key)
	if err != nil {
		s.logger.Warn().Err(err).Str("key", key).Msg("failed to load config metadata")
	}
	return entry, meta, nil
}

func (s *APIServer) getKVEntry(ctx context.Context, kvStoreID, key string) (*kvEntry, error) {
	if key == "" {
		return nil, errKVKeyNotSpecified
	}

	if kvStoreID != "" {
		kvClient, closeFn, err := s.getKVClient(ctx, kvStoreID)
		if err != nil {
			return nil, err
		}
		defer closeFn()

		resp, err := kvClient.Get(ctx, &proto.GetRequest{Key: key})
		if err != nil {
			return nil, err
		}
		return &kvEntry{Value: resp.GetValue(), Found: resp.GetFound(), Revision: resp.GetRevision()}, nil
	}

	if s.kvGetFn == nil {
		return nil, ErrKVAddressNotConfigured
	}

	value, found, revision, err := s.kvGetFn(ctx, key)
	if err != nil {
		return nil, err
	}
	return &kvEntry{Value: value, Found: found, Revision: revision}, nil
}

func (s *APIServer) loadMetadataRecord(ctx context.Context, kvStoreID, key string) (*configMetadataRecord, error) {
	metaKey := metadataKeyFor(key)
	entry, err := s.getKVEntry(ctx, kvStoreID, metaKey)
	if err != nil {
		return nil, err
	}
	if entry == nil || !entry.Found || len(entry.Value) == 0 {
		return nil, nil
	}

	var record configMetadataRecord
	if err := json.Unmarshal(entry.Value, &record); err != nil {
		return nil, err
	}
	return &record, nil
}

func metadataKeyFor(key string) string {
	if key == "" {
		return ""
	}
	return fmt.Sprintf("%s.meta", key)
}

func buildConfigMetadata(service, kvStoreID, key string, format config.ConfigFormat, revision uint64, record *configMetadataRecord) *configMetadata {
	meta := &configMetadata{
		Service:   service,
		KVKey:     key,
		KVStoreID: kvStoreID,
		Revision:  revision,
		Format:    format,
	}

	if record != nil {
		meta.Origin = record.Origin
		meta.LastWriter = record.Writer
		if !record.UpdatedAt.IsZero() {
			ts := record.UpdatedAt.UTC()
			meta.UpdatedAt = &ts
		}
	}

	if meta.Origin == "" {
		meta.Origin = configOriginUnknown
	}

	return meta
}

func (s *APIServer) recordConfigMetadata(ctx context.Context, kvStoreID, key, origin, writer string) {
	if key == "" {
		return
	}

	if origin == "" {
		origin = configOriginUnknown
	}

	record := configMetadataRecord{
		Origin:    origin,
		Writer:    writer,
		UpdatedAt: time.Now().UTC(),
	}

	data, err := json.Marshal(record)
	if err != nil {
		s.logger.Warn().Err(err).Str("key", key).Msg("failed to marshal metadata record")
		return
	}

	if err := s.putConfigToKV(ctx, kvStoreID, metadataKeyFor(key), data); err != nil {
		s.logger.Warn().Err(err).Str("key", key).Msg("failed to persist config metadata")
	}
}

func (s *APIServer) checkConfigKey(ctx context.Context, kvStoreID, key string) (bool, error) {
	if key == "" {
		return false, errKVKeyNotSpecified
	}

	resolvedKey := s.qualifyKVKey(kvStoreID, key)

	entry, err := s.getKVEntry(ctx, kvStoreID, resolvedKey)
	if err != nil {
		return false, err
	}
	return entry != nil && entry.Found, nil
}

func (s *APIServer) seedConfigFromTemplate(ctx context.Context, desc config.ServiceDescriptor, key, kvStoreID string) ([]byte, error) {
	templateData, err := s.fetchTemplateData(ctx, kvStoreID, desc)
	if err != nil {
		return nil, err
	}

	payload := make([]byte, len(templateData))
	copy(payload, templateData)

	if err := s.putConfigToKV(ctx, kvStoreID, key, payload); err != nil {
		return nil, err
	}

	s.recordConfigMetadata(ctx, kvStoreID, key, configOriginSeeded, "system")

	s.logger.Info().
		Str("service", desc.Name).
		Str("kv_key", key).
		Str("kv_store_id", kvStoreID).
		Msg("seeded configuration from template")

	return payload, nil
}

func (s *APIServer) putConfigToKV(ctx context.Context, kvStoreID, key string, value []byte) error {
	if kvStoreID != "" {
		kvClient, closeFn, err := s.getKVClient(ctx, kvStoreID)
		if err != nil {
			return err
		}
		defer closeFn()

		_, err = kvClient.Put(ctx, &proto.PutRequest{Key: key, Value: value, TtlSeconds: 0})
		return err
	}

	if s.kvPutFn == nil {
		return errKVPutUnavailable
	}

	return s.kvPutFn(ctx, key, value, 0)
}

func (s *APIServer) qualifyKVKey(kvStoreID, key string) string {
	if kvStoreID == "" || key == "" || strings.HasPrefix(key, "domains/") {
		return key
	}

	var domain string
	if s != nil {
		domain = s.resolveKVDomain(kvStoreID)
	}
	if domain == "" {
		return key
	}
	return fmt.Sprintf("domains/%s/%s", domain, key)
}

func (s *APIServer) fetchTemplateData(ctx context.Context, kvStoreID string, desc config.ServiceDescriptor) ([]byte, error) {
	templateKey := config.TemplateStorageKey(desc)
	if templateKey != "" {
		if entry, err := s.getKVEntry(ctx, kvStoreID, s.qualifyKVKey(kvStoreID, templateKey)); err == nil {
			if entry != nil && entry.Found && len(entry.Value) > 0 {
				return entry.Value, nil
			}
		} else if s.logger != nil {
			s.logger.Warn().
				Err(err).
				Str("service", desc.Name).
				Str("template_key", templateKey).
				Msg("failed to read template from KV")
		}
	}

	if s.templateRegistry != nil {
		data, _, err := s.templateRegistry.Get(desc.Name)
		if err == nil && len(data) > 0 {
			return data, nil
		}
	}

	return nil, errTemplateUnavailable
}

// defaultKVKeyForService returns a conventional KV key for known services.
// Returns (key, true) if a default exists, otherwise ("", false).
func defaultKVKeyForService(service, serviceType, agentID string) (string, bool) {
	if service == serviceSweep || serviceType == serviceSweep {
		if agentID == "" {
			return "", false
		}
		return fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", agentID), true
	}
	if service == serviceSNMP || serviceType == serviceSNMP || service == "snmp-checker" {
		if agentID == "" {
			return "", false
		}
		return fmt.Sprintf("agents/%s/checkers/snmp/snmp.json", agentID), true
	}
	if service == serviceMapper || serviceType == serviceMapper || service == "serviceradar-mapper" {
		if agentID == "" {
			return "", false
		}
		return fmt.Sprintf("agents/%s/checkers/mapper/mapper.json", agentID), true
	}
	if service == serviceTrapd || serviceType == serviceTrapd || service == "serviceradar-trapd" {
		if agentID == "" {
			return "", false
		}
		return fmt.Sprintf("agents/%s/checkers/trapd/trapd.json", agentID), true
	}
	if service == serviceRPerf || serviceType == serviceRPerf || service == "rperf-checker" {
		if agentID == "" {
			return "", false
		}
		return fmt.Sprintf("agents/%s/checkers/rperf/rperf.json", agentID), true
	}
	if service == serviceSysmon || serviceType == serviceSysmon {
		if agentID == "" {
			return "", false
		}
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
	case "core", "sync", "poller", serviceAgent, "db-event-writer", "zen-consumer":
		return fmt.Sprintf("config/%s.json", service), true
	default:
		return "", false
	}
}

func (s *APIServer) resolveServiceKey(service, serviceType, agentID, pollerID string) (config.ServiceDescriptor, string, bool, error) {
	desc, hasDescriptor := s.lookupServiceDescriptor(service, serviceType, agentID, pollerID)
	if hasDescriptor {
		key, err := desc.ResolveKVKey(config.KeyContext{
			AgentID:  agentID,
			PollerID: pollerID,
		})
		if err != nil {
			return desc, "", true, err
		}
		return desc, key, true, nil
	}

	if agentID != "" {
		if k, ok := defaultKVKeyForService(service, serviceType, agentID); ok {
			return config.ServiceDescriptor{}, k, false, nil
		}
	}

	if k, ok := serviceLevelKeyFor(service); ok {
		return config.ServiceDescriptor{}, k, false, nil
	}
	if serviceType != "" {
		if k, ok := serviceLevelKeyFor(serviceType); ok {
			return config.ServiceDescriptor{}, k, false, nil
		}
	}

	return config.ServiceDescriptor{}, "", false, errConfigKeyUnresolved
}

func (s *APIServer) lookupServiceDescriptor(service, serviceType, agentID, pollerID string) (config.ServiceDescriptor, bool) {
	candidates := uniqueStrings(service, serviceType)

	if agentID != "" {
		for _, candidate := range candidates {
			if desc, ok := config.ServiceDescriptorByType(candidate, config.ConfigScopeAgent); ok {
				return desc, true
			}
		}
	}

	if pollerID != "" {
		for _, candidate := range candidates {
			if desc, ok := config.ServiceDescriptorByType(candidate, config.ConfigScopePoller); ok {
				return desc, true
			}
		}
	}

	for _, candidate := range candidates {
		if desc, ok := config.ServiceDescriptorFor(candidate); ok {
			if desc.Scope == config.ConfigScopeAgent && agentID == "" {
				continue
			}
			if desc.Scope == config.ConfigScopePoller && pollerID == "" {
				continue
			}
			return desc, true
		}
	}

	for _, candidate := range candidates {
		if desc, ok := config.ServiceDescriptorByType(candidate, config.ConfigScopeGlobal); ok {
			return desc, true
		}
	}

	return config.ServiceDescriptor{}, false
}

func uniqueStrings(values ...string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, v := range values {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		result = append(result, v)
	}
	return result
}
