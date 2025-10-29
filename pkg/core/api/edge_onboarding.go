package api

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/mux"

	"github.com/carverauto/serviceradar/pkg/core/auth"
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

type edgePackageCreateRequest struct {
	Label                   string   `json:"label"`
	PollerID                string   `json:"poller_id,omitempty"`
	Site                    string   `json:"site,omitempty"`
	Selectors               []string `json:"selectors,omitempty"`
	MetadataJSON            string   `json:"metadata_json,omitempty"`
	Notes                   string   `json:"notes,omitempty"`
	JoinTokenTTLSeconds     int64    `json:"join_token_ttl_seconds,omitempty"`
	DownloadTokenTTLSeconds int64    `json:"download_token_ttl_seconds,omitempty"`
	DownstreamSPIFFEID      string   `json:"downstream_spiffe_id,omitempty"`
}

type edgePackageCreateResponse struct {
	Package       edgePackageView `json:"package"`
	JoinToken     string          `json:"join_token"`
	DownloadToken string          `json:"download_token"`
	BundlePEM     string          `json:"bundle_pem"`
}

type edgePackageDownloadRequest struct {
	DownloadToken string `json:"download_token"`
}

type edgePackageRevokeRequest struct {
	Reason string `json:"reason,omitempty"`
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

func (s *APIServer) handleCreateEdgePackage(w http.ResponseWriter, r *http.Request) {
	if s.edgeOnboarding == nil {
		writeError(w, "Edge onboarding service is disabled", http.StatusServiceUnavailable)
		return
	}

	var req edgePackageCreateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid JSON payload", http.StatusBadRequest)
		return
	}

	if req.Label == "" {
		writeError(w, "label is required", http.StatusBadRequest)
		return
	}

	if req.JoinTokenTTLSeconds < 0 || req.DownloadTokenTTLSeconds < 0 {
		writeError(w, "ttl values must be non-negative", http.StatusBadRequest)
		return
	}

	var joinTTL, downloadTTL time.Duration
	if req.JoinTokenTTLSeconds > 0 {
		joinTTL = time.Duration(req.JoinTokenTTLSeconds) * time.Second
	}
	if req.DownloadTokenTTLSeconds > 0 {
		downloadTTL = time.Duration(req.DownloadTokenTTLSeconds) * time.Second
	}

	createdBy := ""
	if user, ok := auth.GetUserFromContext(r.Context()); ok && user != nil {
		createdBy = strings.TrimSpace(user.Email)
	}

	createReq := &models.EdgeOnboardingCreateRequest{
		Label:              req.Label,
		PollerID:           req.PollerID,
		Site:               req.Site,
		Selectors:          req.Selectors,
		MetadataJSON:       req.MetadataJSON,
		Notes:              req.Notes,
		CreatedBy:          createdBy,
		JoinTokenTTL:       joinTTL,
		DownloadTokenTTL:   downloadTTL,
		DownstreamSPIFFEID: req.DownstreamSPIFFEID,
	}

	result, err := s.edgeOnboarding.CreatePackage(r.Context(), createReq)
	if err != nil {
		switch {
		case errors.Is(err, models.ErrEdgeOnboardingInvalidRequest):
			writeError(w, err.Error(), http.StatusBadRequest)
		case errors.Is(err, models.ErrEdgeOnboardingPollerConflict):
			writeError(w, err.Error(), http.StatusConflict)
		case errors.Is(err, models.ErrEdgeOnboardingSpireUnavailable):
			writeError(w, "SPIRE admin integration unavailable", http.StatusServiceUnavailable)
		case errors.Is(err, models.ErrEdgeOnboardingDisabled):
			writeError(w, "Edge onboarding service is disabled", http.StatusServiceUnavailable)
		default:
			writeError(w, "failed to create edge package", http.StatusBadGateway)
		}
		return
	}

	response := edgePackageCreateResponse{
		Package:       toEdgePackageView(result.Package),
		JoinToken:     result.JoinToken,
		DownloadToken: result.DownloadToken,
		BundlePEM:     string(result.BundlePEM),
	}

	s.writeJSON(w, http.StatusCreated, response)
}

func (s *APIServer) handleDownloadEdgePackage(w http.ResponseWriter, r *http.Request) {
	if s.edgeOnboarding == nil {
		writeError(w, "Edge onboarding service is disabled", http.StatusServiceUnavailable)
		return
	}

	id := mux.Vars(r)["id"]
	if strings.TrimSpace(id) == "" {
		writeError(w, "package id is required", http.StatusBadRequest)
		return
	}

	var req edgePackageDownloadRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid JSON payload", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(req.DownloadToken) == "" {
		writeError(w, "download_token is required", http.StatusBadRequest)
		return
	}

	actor := ""
	if user, ok := auth.GetUserFromContext(r.Context()); ok && user != nil {
		actor = strings.TrimSpace(user.Email)
	}

	result, err := s.edgeOnboarding.DeliverPackage(r.Context(), &models.EdgeOnboardingDeliverRequest{
		PackageID:     id,
		DownloadToken: strings.TrimSpace(req.DownloadToken),
		Actor:         actor,
		SourceIP:      clientIPFromRequest(r),
	})
	if err != nil {
		switch {
		case errors.Is(err, models.ErrEdgeOnboardingDownloadRequired),
			errors.Is(err, models.ErrEdgeOnboardingInvalidRequest):
			writeError(w, err.Error(), http.StatusBadRequest)
		case errors.Is(err, models.ErrEdgeOnboardingDownloadInvalid):
			writeError(w, err.Error(), http.StatusUnauthorized)
		case errors.Is(err, models.ErrEdgeOnboardingDownloadExpired):
			writeError(w, err.Error(), http.StatusGone)
		case errors.Is(err, models.ErrEdgeOnboardingPackageDelivered),
			errors.Is(err, models.ErrEdgeOnboardingPackageRevoked):
			writeError(w, err.Error(), http.StatusConflict)
		case errors.Is(err, db.ErrEdgePackageNotFound):
			writeError(w, "package not found", http.StatusNotFound)
		case errors.Is(err, models.ErrEdgeOnboardingDisabled):
			writeError(w, err.Error(), http.StatusServiceUnavailable)
		case errors.Is(err, errEdgePackageArchive):
			writeError(w, err.Error(), http.StatusInternalServerError)
		default:
			writeError(w, "failed to deliver edge package", http.StatusBadGateway)
		}
		return
	}

	archive, filename, err := buildEdgePackageArchive(result, time.Now().UTC())
	if err != nil {
		if errors.Is(err, errEdgePackageArchive) {
			writeError(w, err.Error(), http.StatusInternalServerError)
		} else {
			writeError(w, "failed to render edge package artefacts", http.StatusInternalServerError)
		}
		return
	}

	if result.Package != nil {
		w.Header().Set("X-Edge-Package-ID", result.Package.PackageID)
		w.Header().Set("X-Edge-Poller-ID", result.Package.PollerID)
	}
	w.Header().Set("Content-Type", "application/gzip")
	w.Header().Set("Content-Disposition", buildContentDisposition(filename))
	w.Header().Set("Cache-Control", "no-store")

	w.WriteHeader(http.StatusOK)
	if _, err := w.Write(archive); err != nil && s.logger != nil {
		s.logger.Warn().
			Err(err).
			Str("package_id", result.Package.PackageID).
			Msg("edge onboarding: failed to stream archive to client")
	}
}

func (s *APIServer) handleRevokeEdgePackage(w http.ResponseWriter, r *http.Request) {
	if s.edgeOnboarding == nil {
		writeError(w, "Edge onboarding service is disabled", http.StatusServiceUnavailable)
		return
	}

	id := mux.Vars(r)["id"]
	if strings.TrimSpace(id) == "" {
		writeError(w, "package id is required", http.StatusBadRequest)
		return
	}

	var req edgePackageRevokeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, "invalid JSON payload", http.StatusBadRequest)
		return
	}

	actor := ""
	if user, ok := auth.GetUserFromContext(r.Context()); ok && user != nil {
		actor = strings.TrimSpace(user.Email)
	}

	result, err := s.edgeOnboarding.RevokePackage(r.Context(), &models.EdgeOnboardingRevokeRequest{
		PackageID: id,
		Actor:     actor,
		Reason:    strings.TrimSpace(req.Reason),
		SourceIP:  clientIPFromRequest(r),
	})
	if err != nil {
		switch {
		case errors.Is(err, models.ErrEdgeOnboardingInvalidRequest):
			writeError(w, err.Error(), http.StatusBadRequest)
		case errors.Is(err, models.ErrEdgeOnboardingPackageRevoked):
			writeError(w, err.Error(), http.StatusConflict)
		case errors.Is(err, models.ErrEdgeOnboardingSpireUnavailable):
			writeError(w, err.Error(), http.StatusServiceUnavailable)
		case errors.Is(err, db.ErrEdgePackageNotFound):
			writeError(w, "package not found", http.StatusNotFound)
		case errors.Is(err, models.ErrEdgeOnboardingDisabled):
			writeError(w, err.Error(), http.StatusServiceUnavailable)
		default:
			writeError(w, "failed to revoke edge package", http.StatusBadGateway)
		}
		return
	}

	s.writeJSON(w, http.StatusOK, toEdgePackageView(result.Package))
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

func clientIPFromRequest(r *http.Request) string {
	if r == nil {
		return ""
	}
	if xfwd := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); xfwd != "" {
		parts := strings.Split(xfwd, ",")
		if len(parts) > 0 {
			if candidate := strings.TrimSpace(parts[0]); candidate != "" {
				return candidate
			}
		}
	}
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err == nil && host != "" {
		return host
	}
	return strings.TrimSpace(r.RemoteAddr)
}
