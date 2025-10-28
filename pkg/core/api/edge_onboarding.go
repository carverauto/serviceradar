package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/mux"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

const defaultEdgePackageLimit = 100

type edgePackageView struct {
	PackageID          string     `json:"package_id"`
	Label              string     `json:"label"`
	PollerID           string     `json:"poller_id"`
	Site               string     `json:"site,omitempty"`
	Status             string     `json:"status"`
	DownstreamSPIFFEID string     `json:"downstream_spiffe_id"`
	Selectors          []string   `json:"selectors,omitempty"`
	JoinTokenExpiresAt time.Time  `json:"join_token_expires_at"`
	DownloadExpiresAt  time.Time  `json:"download_token_expires_at"`
	CreatedBy          string     `json:"created_by"`
	CreatedAt          time.Time  `json:"created_at"`
	UpdatedAt          time.Time  `json:"updated_at"`
	DeliveredAt        *time.Time `json:"delivered_at,omitempty"`
	ActivatedAt        *time.Time `json:"activated_at,omitempty"`
	ActivatedFromIP    *string    `json:"activated_from_ip,omitempty"`
	LastSeenSPIFFEID   *string    `json:"last_seen_spiffe_id,omitempty"`
	RevokedAt          *time.Time `json:"revoked_at,omitempty"`
	MetadataJSON       string     `json:"metadata_json,omitempty"`
	Notes              string     `json:"notes,omitempty"`
}

type edgeEventView struct {
	EventTime   time.Time `json:"event_time"`
	EventType   string    `json:"event_type"`
	Actor       string    `json:"actor"`
	SourceIP    string    `json:"source_ip,omitempty"`
	DetailsJSON string    `json:"details_json,omitempty"`
}

func (s *APIServer) handleListEdgePackages(w http.ResponseWriter, r *http.Request) {
	if s.edgeOnboarding == nil {
		writeError(w, "Edge onboarding service is disabled", http.StatusServiceUnavailable)
		return
	}

	query := r.URL.Query()

	filter := &models.EdgeOnboardingListFilter{
		PollerID: query.Get("poller_id"),
	}

	if limitRaw := query.Get("limit"); limitRaw != "" {
		if limit, err := strconv.Atoi(limitRaw); err == nil && limit > 0 {
			filter.Limit = limit
		} else {
			writeError(w, "limit must be a positive integer", http.StatusBadRequest)
			return
		}
	}

	if filter.Limit == 0 {
		filter.Limit = defaultEdgePackageLimit
	}

	statusParams := query["status"]
	if len(statusParams) > 0 {
		var statuses []models.EdgeOnboardingStatus
		for _, raw := range statusParams {
			for _, token := range strings.Split(raw, ",") {
				trimmed := strings.TrimSpace(token)
				if trimmed == "" {
					continue
				}
				status := models.EdgeOnboardingStatus(trimmed)
				switch status {
				case models.EdgeOnboardingStatusIssued,
					models.EdgeOnboardingStatusDelivered,
					models.EdgeOnboardingStatusActivated,
					models.EdgeOnboardingStatusRevoked,
					models.EdgeOnboardingStatusExpired:
					statuses = append(statuses, status)
				default:
					writeError(w, "unknown status "+trimmed, http.StatusBadRequest)
					return
				}
			}
		}
		filter.Statuses = statuses
	}

	packages, err := s.edgeOnboarding.ListPackages(r.Context(), filter)
	if err != nil {
		writeError(w, "failed to list edge packages", http.StatusBadGateway)
		return
	}

	views := make([]edgePackageView, 0, len(packages))
	for _, pkg := range packages {
		views = append(views, toEdgePackageView(pkg))
	}

	s.writeJSON(w, http.StatusOK, views)
}

func (s *APIServer) handleGetEdgePackage(w http.ResponseWriter, r *http.Request) {
	if s.edgeOnboarding == nil {
		writeError(w, "Edge onboarding service is disabled", http.StatusServiceUnavailable)
		return
	}

	id := mux.Vars(r)["id"]
	if id == "" {
		writeError(w, "package id is required", http.StatusBadRequest)
		return
	}

	pkg, err := s.edgeOnboarding.GetPackage(r.Context(), id)
	if err != nil {
		if errors.Is(err, db.ErrEdgePackageNotFound) {
			writeError(w, "package not found", http.StatusNotFound)
		} else {
			writeError(w, "failed to fetch package", http.StatusBadGateway)
		}
		return
	}

	s.writeJSON(w, http.StatusOK, toEdgePackageView(pkg))
}

func (s *APIServer) handleListEdgePackageEvents(w http.ResponseWriter, r *http.Request) {
	if s.edgeOnboarding == nil {
		writeError(w, "Edge onboarding service is disabled", http.StatusServiceUnavailable)
		return
	}

	id := mux.Vars(r)["id"]
	if id == "" {
		writeError(w, "package id is required", http.StatusBadRequest)
		return
	}

	limit := 50
	if limitRaw := r.URL.Query().Get("limit"); limitRaw != "" {
		value, err := strconv.Atoi(limitRaw)
		if err != nil || value <= 0 {
			writeError(w, "limit must be a positive integer", http.StatusBadRequest)
			return
		}
		limit = value
	}

	events, err := s.edgeOnboarding.ListEvents(r.Context(), id, limit)
	if err != nil {
		if errors.Is(err, db.ErrEdgePackageNotFound) {
			writeError(w, "package not found", http.StatusNotFound)
		} else {
			writeError(w, "failed to fetch package events", http.StatusBadGateway)
		}
		return
	}

	views := make([]edgeEventView, 0, len(events))
	for _, ev := range events {
		views = append(views, edgeEventView{
			EventTime:   ev.EventTime,
			EventType:   ev.EventType,
			Actor:       ev.Actor,
			SourceIP:    ev.SourceIP,
			DetailsJSON: ev.DetailsJSON,
		})
	}

	s.writeJSON(w, http.StatusOK, views)
}

func (s *APIServer) handleCreateEdgePackage(w http.ResponseWriter, _ *http.Request) {
	if s.edgeOnboarding == nil {
		writeError(w, "Edge onboarding service is disabled", http.StatusServiceUnavailable)
		return
	}

	writeError(w, "edge onboarding provisioning API is under construction", http.StatusNotImplemented)
}

func toEdgePackageView(pkg *models.EdgeOnboardingPackage) edgePackageView {
	view := edgePackageView{
		PackageID:          pkg.PackageID,
		Label:              pkg.Label,
		PollerID:           pkg.PollerID,
		Site:               pkg.Site,
		Status:             string(pkg.Status),
		DownstreamSPIFFEID: pkg.DownstreamSPIFFEID,
		Selectors:          pkg.Selectors,
		JoinTokenExpiresAt: pkg.JoinTokenExpiresAt,
		DownloadExpiresAt:  pkg.DownloadTokenExpiresAt,
		CreatedBy:          pkg.CreatedBy,
		CreatedAt:          pkg.CreatedAt,
		UpdatedAt:          pkg.UpdatedAt,
		MetadataJSON:       pkg.MetadataJSON,
		Notes:              pkg.Notes,
	}

	if pkg.DeliveredAt != nil {
		view.DeliveredAt = pkg.DeliveredAt
	}
	if pkg.ActivatedAt != nil {
		view.ActivatedAt = pkg.ActivatedAt
	}
	if pkg.RevokedAt != nil {
		view.RevokedAt = pkg.RevokedAt
	}
	if pkg.ActivatedFromIP != nil {
		view.ActivatedFromIP = pkg.ActivatedFromIP
	}
	if pkg.LastSeenSPIFFEID != nil {
		view.LastSeenSPIFFEID = pkg.LastSeenSPIFFEID
	}

	return view
}
