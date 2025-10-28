package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/carverauto/serviceradar/pkg/spireadmin"
	types "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
)

const fallbackJoinTokenTTL = 15 * time.Minute

type createSpireJoinTokenRequest struct {
	ClientSPIFFEID     string                  `json:"client_spiffe_id,omitempty"`
	TTLSeconds         int                     `json:"ttl_seconds,omitempty"`
	RegisterDownstream bool                    `json:"register_downstream,omitempty"`
	Downstream         *downstreamEntryRequest `json:"downstream,omitempty"`
}

type downstreamEntryRequest struct {
	SpiffeID           string   `json:"spiffe_id"`
	Selectors          []string `json:"selectors"`
	X509SVIDTTLSeconds int      `json:"x509_svid_ttl_seconds,omitempty"`
	JWTSVIDTTLSeconds  int      `json:"jwt_svid_ttl_seconds,omitempty"`
	Admin              bool     `json:"admin,omitempty"`
	StoreSVID          bool     `json:"store_svid,omitempty"`
	DNSNames           []string `json:"dns_names,omitempty"`
	FederatesWith      []string `json:"federates_with,omitempty"`
}

type createSpireJoinTokenResponse struct {
	Token             string    `json:"token"`
	ExpiresAt         time.Time `json:"expires_at"`
	ParentSPIFFEID    string    `json:"parent_spiffe_id"`
	DownstreamEntryID string    `json:"downstream_entry_id,omitempty"`
}

var errSelectorRequired = errors.New("at least one selector is required")

func (s *APIServer) handleCreateSpireJoinToken(w http.ResponseWriter, r *http.Request) {
	if s.spireAdminClient == nil || s.spireAdminConfig == nil || !s.spireAdminConfig.Enabled {
		writeError(w, "SPIRE admin integration is not enabled", http.StatusServiceUnavailable)
		return
	}

	var req createSpireJoinTokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	ctx := r.Context()

	defaultTTL := fallbackJoinTokenTTL
	if s.spireAdminConfig != nil && s.spireAdminConfig.JoinTokenTTL > 0 {
		defaultTTL = time.Duration(s.spireAdminConfig.JoinTokenTTL)
	}

	if req.TTLSeconds > 0 {
		defaultTTL = time.Duration(req.TTLSeconds) * time.Second
	}

	params := spireadmin.JoinTokenParams{
		TTL:     defaultTTL,
		AgentID: req.ClientSPIFFEID,
	}

	joinToken, err := s.spireAdminClient.CreateJoinToken(ctx, params)
	if err != nil {
		writeError(w, err.Error(), http.StatusBadGateway)
		return
	}

	response := createSpireJoinTokenResponse{
		Token:          joinToken.Token,
		ExpiresAt:      joinToken.Expires,
		ParentSPIFFEID: joinToken.ParentID,
	}

	if req.RegisterDownstream {
		if req.Downstream == nil {
			writeError(w, "downstream configuration is required", http.StatusBadRequest)
			return
		}

		selectors, err := buildSelectorList(req.Downstream.Selectors)
		if err != nil {
			writeError(w, err.Error(), http.StatusBadRequest)
			return
		}

		downstreamParams := spireadmin.DownstreamEntryParams{
			ParentID:      joinToken.ParentID,
			SpiffeID:      req.Downstream.SpiffeID,
			Selectors:     selectors,
			Admin:         req.Downstream.Admin,
			StoreSVID:     req.Downstream.StoreSVID,
			DNSNames:      req.Downstream.DNSNames,
			FederatesWith: req.Downstream.FederatesWith,
		}

		if req.Downstream.X509SVIDTTLSeconds > 0 {
			downstreamParams.X509SVIDTTL = time.Duration(req.Downstream.X509SVIDTTLSeconds) * time.Second
		}
		if req.Downstream.JWTSVIDTTLSeconds > 0 {
			downstreamParams.JWTSVIDTTL = time.Duration(req.Downstream.JWTSVIDTTLSeconds) * time.Second
		}

		entryResult, err := s.spireAdminClient.CreateDownstreamEntry(ctx, downstreamParams)
		if err != nil {
			writeError(w, err.Error(), http.StatusBadGateway)
			return
		}
		response.DownstreamEntryID = entryResult.EntryID
	}

	s.writeJSON(w, http.StatusCreated, response)
}

func buildSelectorList(raw []string) ([]*types.Selector, error) {
	if len(raw) == 0 {
		return nil, errSelectorRequired
	}
	selectors := make([]*types.Selector, 0, len(raw))
	for _, s := range raw {
		sel, err := spireadmin.ToProtoSelector(s)
		if err != nil {
			return nil, err
		}
		selectors = append(selectors, sel)
	}
	return selectors, nil
}
