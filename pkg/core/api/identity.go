package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/gorilla/mux"

	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/models"
)

const defaultSightingActor = "system"

func (s *APIServer) handleListSightings(w http.ResponseWriter, r *http.Request) {
	if s.deviceRegistry == nil {
		s.writeAPIError(w, http.StatusServiceUnavailable, "device registry unavailable")
		return
	}

	partition := r.URL.Query().Get("partition")
	limit := 100
	offset := 0
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if raw := r.URL.Query().Get("offset"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed >= 0 {
			offset = parsed
		}
	}

	sightings, err := s.deviceRegistry.ListSightings(r.Context(), partition, limit, offset)
	if err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}

	total, err := s.deviceRegistry.CountSightings(r.Context(), partition)
	if err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}

	payload := struct {
		Items    []models.NetworkSighting             `json:"items"`
		Total    int64                                `json:"total"`
		Limit    int                                  `json:"limit"`
		Offset   int                                  `json:"offset"`
		Identity *models.IdentityReconciliationConfig `json:"identity,omitempty"`
	}{
		Items:    make([]models.NetworkSighting, 0, len(sightings)),
		Total:    total,
		Limit:    limit,
		Offset:   offset,
		Identity: s.identityConfig,
	}

	for _, sght := range sightings {
		if sght == nil {
			continue
		}
		payload.Items = append(payload.Items, *sght)
	}

	s.writeJSON(w, http.StatusOK, payload)
}

func (s *APIServer) handleReconcileSightings(w http.ResponseWriter, r *http.Request) {
	if s.deviceRegistry == nil {
		s.writeAPIError(w, http.StatusServiceUnavailable, "device registry unavailable")
		return
	}

	if err := s.deviceRegistry.ReconcileSightings(r.Context()); err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}

	s.writeJSON(w, http.StatusAccepted, map[string]string{"status": "reconciliation triggered"})
}

func (s *APIServer) handlePromoteSighting(w http.ResponseWriter, r *http.Request) {
	if s.deviceRegistry == nil {
		s.writeAPIError(w, http.StatusServiceUnavailable, "device registry unavailable")
		return
	}

	vars := mux.Vars(r)
	sightingID := vars["id"]
	if sightingID == "" {
		s.writeAPIError(w, http.StatusBadRequest, "sighting_id is required")
		return
	}

	actor := defaultSightingActor
	if user, ok := auth.GetUserFromContext(r.Context()); ok && user != nil && user.Email != "" {
		actor = user.Email
	}

	update, err := s.deviceRegistry.PromoteSighting(r.Context(), sightingID, actor)
	if err != nil {
		s.writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}

	response := map[string]interface{}{
		"status":      "promoted",
		"sighting_id": sightingID,
	}

	if update != nil {
		if update.DeviceID != "" {
			response["device_id"] = update.DeviceID
		}
		response["ip"] = update.IP
		response["partition"] = update.Partition
	}

	s.writeJSON(w, http.StatusOK, response)
}

func (s *APIServer) handleDismissSighting(w http.ResponseWriter, r *http.Request) {
	if s.deviceRegistry == nil {
		s.writeAPIError(w, http.StatusServiceUnavailable, "device registry unavailable")
		return
	}

	vars := mux.Vars(r)
	sightingID := vars["id"]
	if sightingID == "" {
		s.writeAPIError(w, http.StatusBadRequest, "sighting_id is required")
		return
	}

	var body struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)

	actor := defaultSightingActor
	if user, ok := auth.GetUserFromContext(r.Context()); ok && user != nil && user.Email != "" {
		actor = user.Email
	}

	if err := s.deviceRegistry.DismissSighting(r.Context(), sightingID, actor, body.Reason); err != nil {
		s.writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}

	s.writeJSON(w, http.StatusOK, map[string]string{
		"status":      "dismissed",
		"sighting_id": sightingID,
	})
}

func (s *APIServer) handleSightingEvents(w http.ResponseWriter, r *http.Request) {
	if s.deviceRegistry == nil {
		s.writeAPIError(w, http.StatusServiceUnavailable, "device registry unavailable")
		return
	}

	vars := mux.Vars(r)
	sightingID := vars["id"]
	if sightingID == "" {
		s.writeAPIError(w, http.StatusBadRequest, "sighting_id is required")
		return
	}

	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			limit = parsed
		}
	}

	events, err := s.deviceRegistry.ListSightingEvents(r.Context(), sightingID, limit)
	if err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}

	payload := struct {
		Items []*models.SightingEvent `json:"items"`
	}{
		Items: events,
	}

	s.writeJSON(w, http.StatusOK, payload)
}

func (s *APIServer) handleListSubnetPolicies(w http.ResponseWriter, r *http.Request) {
	if s.dbService == nil {
		s.writeAPIError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}

	limit := 100
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			limit = parsed
		}
	}

	policies, err := s.dbService.ListSubnetPolicies(r.Context(), limit)
	if err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}

	payload := struct {
		Items []*models.SubnetPolicy `json:"items"`
	}{
		Items: policies,
	}

	s.writeJSON(w, http.StatusOK, payload)
}

func (s *APIServer) handleMergeAuditHistory(w http.ResponseWriter, r *http.Request) {
	if s.dbService == nil {
		s.writeAPIError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}

	deviceID := r.URL.Query().Get("device_id")
	limit := 100
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			limit = parsed
		}
	}

	events, err := s.dbService.ListMergeAuditEvents(r.Context(), deviceID, limit)
	if err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}

	payload := struct {
		Items []*models.MergeAuditEvent `json:"items"`
	}{
		Items: events,
	}

	s.writeJSON(w, http.StatusOK, payload)
}

func (s *APIServer) handleGetIdentityConfig(w http.ResponseWriter, r *http.Request) {
	kvStoreID := r.URL.Query().Get("kv_store_id")
	coreKey, ok := serviceLevelKeyFor("core")
	if !ok {
		s.writeAPIError(w, http.StatusInternalServerError, "core config key unresolved")
		return
	}

	resolvedKey := s.qualifyKVKey(kvStoreID, coreKey)
	entry, _, err := s.loadConfigEntry(r.Context(), kvStoreID, resolvedKey)
	if err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}

	identity := &models.IdentityReconciliationConfig{}

	if entry != nil && entry.Found && len(entry.Value) > 0 {
		if parsed, parseErr := extractIdentityConfig(entry.Value); parseErr == nil && parsed != nil {
			identity = parsed
		}
	}

	if identity == nil && s.identityConfig != nil {
		identity = s.identityConfig
	}

	response := map[string]interface{}{
		"identity": identity,
	}
	if entry != nil {
		response["revision"] = entry.Revision
	}

	s.writeJSON(w, http.StatusOK, response)
}

func (s *APIServer) handleUpdateIdentityConfig(w http.ResponseWriter, r *http.Request) {
	kvStoreID := r.URL.Query().Get("kv_store_id")
	coreKey, ok := serviceLevelKeyFor("core")
	if !ok {
		s.writeAPIError(w, http.StatusInternalServerError, "core config key unresolved")
		return
	}

	var payload struct {
		Identity *models.IdentityReconciliationConfig `json:"identity"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		s.writeAPIError(w, http.StatusBadRequest, "invalid JSON payload")
		return
	}
	if payload.Identity == nil {
		s.writeAPIError(w, http.StatusBadRequest, "identity payload is required")
		return
	}

	normalized := normalizeIdentityConfig(payload.Identity)

	resolvedKey := s.qualifyKVKey(kvStoreID, coreKey)
	entry, _, err := s.loadConfigEntry(r.Context(), kvStoreID, resolvedKey)
	if err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if kvEntryMissing(entry) || len(entry.Value) == 0 {
		s.writeAPIError(w, http.StatusNotFound, "core configuration not found in KV")
		return
	}

	configMap := make(map[string]interface{})
	if err := json.Unmarshal(entry.Value, &configMap); err != nil {
		s.writeAPIError(w, http.StatusBadRequest, "failed to parse existing core configuration")
		return
	}

	identityBytes, _ := json.Marshal(normalized)
	var identityAny interface{}
	_ = json.Unmarshal(identityBytes, &identityAny)
	configMap["identity_reconciliation"] = identityAny

	updated, err := json.MarshalIndent(configMap, "", "  ")
	if err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, "failed to serialize identity configuration")
		return
	}

	if err := s.putConfigToKV(r.Context(), kvStoreID, resolvedKey, updated); err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}

	actor := defaultSightingActor
	if user, ok := auth.GetUserFromContext(r.Context()); ok && user != nil && strings.TrimSpace(user.Email) != "" {
		actor = user.Email
	}
	s.recordConfigMetadata(r.Context(), kvStoreID, resolvedKey, configOriginUser, actor)

	s.writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":   "updated",
		"revision": entry.Revision + 1,
	})
}

func extractIdentityConfig(raw []byte) (*models.IdentityReconciliationConfig, error) {
	if len(raw) == 0 {
		return nil, nil
	}

	var cfg map[string]interface{}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, err
	}

	section, ok := cfg["identity_reconciliation"]
	if !ok {
		return nil, nil
	}

	sectionBytes, err := json.Marshal(section)
	if err != nil {
		return nil, err
	}

	var identity models.IdentityReconciliationConfig
	if err := json.Unmarshal(sectionBytes, &identity); err != nil {
		return nil, err
	}

	return &identity, nil
}

func normalizeIdentityConfig(cfg *models.IdentityReconciliationConfig) *models.IdentityReconciliationConfig {
	if cfg == nil {
		return &models.IdentityReconciliationConfig{}
	}

	if cfg.Promotion.MinPersistence < 0 {
		cfg.Promotion.MinPersistence = 0
	}
	if cfg.Fingerprinting.PortBudget < 0 {
		cfg.Fingerprinting.PortBudget = 0
	}
	if cfg.Fingerprinting.Timeout < 0 {
		cfg.Fingerprinting.Timeout = 0
	}
	if cfg.Reaper.Interval < 0 {
		cfg.Reaper.Interval = 0
	}

	if cfg.Reaper.Profiles == nil {
		cfg.Reaper.Profiles = make(map[string]models.IdentityReaperProfile)
	}
	for name, profile := range cfg.Reaper.Profiles {
		if profile.TTL < 0 {
			profile.TTL = 0
		}
		cfg.Reaper.Profiles[name] = profile
	}

	if cfg.Drift.BaselineDevices < 0 {
		cfg.Drift.BaselineDevices = 0
	}
	if cfg.Drift.TolerancePercent < 0 {
		cfg.Drift.TolerancePercent = 0
	}

	if !cfg.Fingerprinting.Enabled && cfg.Promotion.RequireFingerprint {
		cfg.Promotion.RequireFingerprint = false
	}

	return cfg
}
