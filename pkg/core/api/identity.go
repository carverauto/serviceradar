package api

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/gorilla/mux"

	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/models"
)

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

	actor := "system"
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

	actor := "system"
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
