package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/mux"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

type stubEdgeOnboardingService struct {
	createResult   *models.EdgeOnboardingCreateResult
	createErr      error
	deliverResult  *models.EdgeOnboardingDeliverResult
	deliverErr     error
	revokeResult   *models.EdgeOnboardingRevokeResult
	revokeErr      error
	lastDeliverReq *models.EdgeOnboardingDeliverRequest
	lastRevokeReq  *models.EdgeOnboardingRevokeRequest
	deleteErr      error
	lastDeleteID   string
	selectors      []string
	metadata       map[models.EdgeOnboardingComponentType]map[string]string
}

func (s *stubEdgeOnboardingService) ListPackages(context.Context, *models.EdgeOnboardingListFilter) ([]*models.EdgeOnboardingPackage, error) {
	return nil, nil
}

func (s *stubEdgeOnboardingService) GetPackage(context.Context, string) (*models.EdgeOnboardingPackage, error) {
	return nil, nil
}

func (s *stubEdgeOnboardingService) ListEvents(context.Context, string, int) ([]*models.EdgeOnboardingEvent, error) {
	return nil, nil
}

func (s *stubEdgeOnboardingService) CreatePackage(context.Context, *models.EdgeOnboardingCreateRequest) (*models.EdgeOnboardingCreateResult, error) {
	return s.createResult, s.createErr
}

func (s *stubEdgeOnboardingService) DeliverPackage(_ context.Context, req *models.EdgeOnboardingDeliverRequest) (*models.EdgeOnboardingDeliverResult, error) {
	s.lastDeliverReq = req
	return s.deliverResult, s.deliverErr
}

func (s *stubEdgeOnboardingService) RevokePackage(_ context.Context, req *models.EdgeOnboardingRevokeRequest) (*models.EdgeOnboardingRevokeResult, error) {
	s.lastRevokeReq = req
	return s.revokeResult, s.revokeErr
}

func (s *stubEdgeOnboardingService) DeletePackage(_ context.Context, packageID string) error {
	s.lastDeleteID = packageID
	return s.deleteErr
}

func (s *stubEdgeOnboardingService) DefaultSelectors() []string {
	if len(s.selectors) == 0 {
		return nil
	}
	out := make([]string, len(s.selectors))
	copy(out, s.selectors)
	return out
}

func (s *stubEdgeOnboardingService) MetadataDefaults() map[models.EdgeOnboardingComponentType]map[string]string {
	if len(s.metadata) == 0 {
		return nil
	}
	result := make(map[models.EdgeOnboardingComponentType]map[string]string, len(s.metadata))
	for componentType, values := range s.metadata {
		clone := make(map[string]string, len(values))
		for key, value := range values {
			clone[key] = value
		}
		result[componentType] = clone
	}
	return result
}

func (s *stubEdgeOnboardingService) SetAllowedPollerCallback(func([]string)) {}

func TestHandleGetEdgePackageDefaultsSuccess(t *testing.T) {
	service := &stubEdgeOnboardingService{
		selectors: []string{"unix:uid:0", "unix:user:root"},
		metadata: map[models.EdgeOnboardingComponentType]map[string]string{
			models.EdgeOnboardingComponentTypePoller: {
				"core_address":   "core:50052",
				"core_spiffe_id": "spiffe://example.org/ns/demo/sa/serviceradar-core",
			},
		},
	}

	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	req := httptest.NewRequest(http.MethodGet, "/api/admin/edge-packages/defaults", nil)
	rec := httptest.NewRecorder()

	server.handleGetEdgePackageDefaults(rec, req)

	resp := rec.Result()
	defer func() {
		_ = resp.Body.Close()
	}()

	require.Equal(t, http.StatusOK, resp.StatusCode)

	var payload edgePackageDefaultsResponse
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&payload))
	assert.ElementsMatch(t, []string{"unix:uid:0", "unix:user:root"}, payload.Selectors)
	require.Contains(t, payload.Metadata, "poller")
	assert.Equal(t, "core:50052", payload.Metadata["poller"]["core_address"])
}

func TestHandleGetEdgePackageDefaultsDisabled(t *testing.T) {
	server := NewAPIServer(models.CORSConfig{})

	req := httptest.NewRequest(http.MethodGet, "/api/admin/edge-packages/defaults", nil)
	rec := httptest.NewRecorder()

	server.handleGetEdgePackageDefaults(rec, req)

	resp := rec.Result()
	defer func() {
		_ = resp.Body.Close()
	}()

	require.Equal(t, http.StatusServiceUnavailable, resp.StatusCode)
}

func TestHandleCreateEdgePackageSuccess(t *testing.T) {
	service := &stubEdgeOnboardingService{
		createResult: &models.EdgeOnboardingCreateResult{
			Package: &models.EdgeOnboardingPackage{
				PackageID:              "pkg-1",
				Label:                  "Edge Poller",
				ComponentID:            "edge-poller",
				ComponentType:          models.EdgeOnboardingComponentTypePoller,
				ParentType:             models.EdgeOnboardingComponentTypeNone,
				ParentID:               "",
				PollerID:               "edge-poller",
				Status:                 models.EdgeOnboardingStatusIssued,
				DownstreamSPIFFEID:     "spiffe://example.org/ns/edge/edge-poller",
				JoinTokenExpiresAt:     time.Now().Add(5 * time.Minute),
				DownloadTokenExpiresAt: time.Now().Add(24 * time.Hour),
				CreatedBy:              "tester@example.com",
				CreatedAt:              time.Now(),
				UpdatedAt:              time.Now(),
			},
			JoinToken:     "join-token",
			DownloadToken: "download-token",
			BundlePEM:     []byte("PEM"),
		},
	}

	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	body, _ := json.Marshal(edgePackageCreateRequest{Label: "Edge Poller"})
	req := httptest.NewRequest(http.MethodPost, "/api/admin/edge-packages", bytes.NewReader(body))
	rec := httptest.NewRecorder()

	server.handleCreateEdgePackage(rec, req)

	resp := rec.Result()
	defer func() {
		_ = resp.Body.Close()
	}()

	require.Equal(t, http.StatusCreated, resp.StatusCode)

	var payload edgePackageCreateResponse
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&payload))
	assert.Equal(t, "join-token", payload.JoinToken)
	assert.Equal(t, "download-token", payload.DownloadToken)
	assert.Equal(t, "PEM", payload.BundlePEM)
	assert.Equal(t, "Edge Poller", payload.Package.Label)
	assert.Equal(t, "edge-poller", payload.Package.ComponentID)
}

func TestHandleCreateEdgePackageInvalid(t *testing.T) {
	service := &stubEdgeOnboardingService{}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	req := httptest.NewRequest(http.MethodPost, "/api/admin/edge-packages", bytes.NewReader([]byte(`{"poller_id":"edge"}`)))
	rec := httptest.NewRecorder()

	server.handleCreateEdgePackage(rec, req)

	assert.Equal(t, http.StatusBadRequest, rec.Code)
}

func TestHandleCreateEdgePackageConflict(t *testing.T) {
	service := &stubEdgeOnboardingService{
		createErr: models.ErrEdgeOnboardingPollerConflict,
	}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	body, _ := json.Marshal(edgePackageCreateRequest{Label: "Edge Poller"})
	req := httptest.NewRequest(http.MethodPost, "/api/admin/edge-packages", bytes.NewReader(body))
	rec := httptest.NewRecorder()

	server.handleCreateEdgePackage(rec, req)

	assert.Equal(t, http.StatusConflict, rec.Code)
}

func TestHandleDownloadEdgePackageSuccess(t *testing.T) {
	now := time.Unix(1710000000, 0).UTC()
	metadata := `{
		"core_address": "core:50052",
		"core_spiffe_id": "spiffe://example.org/ns/demo/sa/serviceradar-core",
		"spire_parent_id": "spiffe://example.org/spire/agent/upstream",
		"spire_upstream_address": "spire.example.org",
		"spire_upstream_port": "18081",
		"agent_address": "agent:50051",
		"agent_spiffe_id": "spiffe://example.org/services/agent",
		"trust_domain": "example.org"
	}`

	service := &stubEdgeOnboardingService{
		deliverResult: &models.EdgeOnboardingDeliverResult{
			Package: &models.EdgeOnboardingPackage{
				PackageID:              "pkg-1",
				Label:                  "Edge Poller",
				ComponentID:            "edge-poller",
				ComponentType:          models.EdgeOnboardingComponentTypePoller,
				ParentType:             models.EdgeOnboardingComponentTypeNone,
				ParentID:               "",
				PollerID:               "edge-poller",
				Status:                 models.EdgeOnboardingStatusIssued,
				DownstreamSPIFFEID:     "spiffe://example.org/ns/edge/edge-poller",
				JoinTokenExpiresAt:     now.Add(5 * time.Minute),
				DownloadTokenExpiresAt: now.Add(30 * time.Minute),
				CreatedAt:              now,
				UpdatedAt:              now,
				MetadataJSON:           metadata,
			},
			JoinToken: "join-token",
			BundlePEM: []byte("bundle"),
		},
	}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	body, _ := json.Marshal(edgePackageDownloadRequest{DownloadToken: "edge-download"})
	req := httptest.NewRequest(http.MethodPost, "/api/admin/edge-packages/pkg-1/download", bytes.NewReader(body))
	req = mux.SetURLVars(req, map[string]string{"id": "pkg-1"})
	req = req.WithContext(context.WithValue(req.Context(), auth.UserKey, &models.User{Email: "ops@example.com"}))

	rec := httptest.NewRecorder()
	server.handleDownloadEdgePackage(rec, req)

	resp := rec.Result()
	defer func() { _ = resp.Body.Close() }()

	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, "application/gzip", resp.Header.Get("Content-Type"))
	assert.Contains(t, resp.Header.Get("Content-Disposition"), "edge-package-edge-poller")
	assert.Equal(t, "pkg-1", resp.Header.Get("X-Edge-Package-ID"))
	assert.Equal(t, "edge-poller", resp.Header.Get("X-Edge-Poller-ID"))

	bodyBytes, err := io.ReadAll(resp.Body)
	require.NoError(t, err)

	gzr, err := gzip.NewReader(bytes.NewReader(bodyBytes))
	require.NoError(t, err)
	defer func() { _ = gzr.Close() }()

	tr := tar.NewReader(gzr)
	files := make(map[string][]byte)

	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		require.NoError(t, err)
		if hdr.FileInfo().IsDir() {
			continue
		}
		content, err := io.ReadAll(tr)
		require.NoError(t, err)
		files[hdr.Name] = content
	}

	require.Contains(t, files, "edge-poller.env")
	require.Contains(t, files, "README.txt")
	require.Contains(t, files, "metadata.json")
	require.Contains(t, files, "spire/upstream-join-token")
	require.Contains(t, files, "spire/upstream-bundle.pem")

	envContent := string(files["edge-poller.env"])
	assert.Contains(t, envContent, "CORE_ADDRESS=core:50052")
	assert.Contains(t, envContent, "POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID=spiffe://example.org/ns/edge/edge-poller")
	assert.Contains(t, envContent, "NESTED_SPIRE_PARENT_ID=spiffe://example.org/spire/agent/upstream")
	assert.Contains(t, envContent, "NESTED_SPIRE_AGENT_SPIFFE_ID=spiffe://example.org/services/agent")
	assert.Contains(t, envContent, "NESTED_SPIRE_DOWNSTREAM_SPIFFE_ID=spiffe://example.org/ns/edge/edge-poller")

	assert.Equal(t, "join-token\n", string(files["spire/upstream-join-token"]))
	assert.Equal(t, "bundle\n", string(files["spire/upstream-bundle.pem"]))

	var metaPayload map[string]interface{}
	require.NoError(t, json.Unmarshal(files["metadata.json"], &metaPayload))
	assert.Equal(t, "pkg-1", metaPayload["package_id"])
	assert.Equal(t, "edge-poller", metaPayload["poller_id"])

	readme := string(files["README.txt"])
	assert.Contains(t, readme, "Package ID: pkg-1")

	require.NotNil(t, service.lastDeliverReq)
	assert.Equal(t, "pkg-1", service.lastDeliverReq.PackageID)
	assert.Equal(t, "edge-download", service.lastDeliverReq.DownloadToken)
	assert.Equal(t, "ops@example.com", service.lastDeliverReq.Actor)
	assert.Equal(t, "192.0.2.1", service.lastDeliverReq.SourceIP)
}

func TestHandleDownloadEdgePackageMissingToken(t *testing.T) {
	service := &stubEdgeOnboardingService{}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	req := httptest.NewRequest(http.MethodPost, "/api/admin/edge-packages/pkg-1/download", bytes.NewReader([]byte(`{}`)))
	req = mux.SetURLVars(req, map[string]string{"id": "pkg-1"})

	rec := httptest.NewRecorder()
	server.handleDownloadEdgePackage(rec, req)

	assert.Equal(t, http.StatusBadRequest, rec.Code)
}

func TestHandleDownloadEdgePackageInvalidToken(t *testing.T) {
	service := &stubEdgeOnboardingService{
		deliverErr: models.ErrEdgeOnboardingDownloadInvalid,
	}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	body, _ := json.Marshal(edgePackageDownloadRequest{DownloadToken: "wrong"})
	req := httptest.NewRequest(http.MethodPost, "/api/admin/edge-packages/pkg-1/download", bytes.NewReader(body))
	req = mux.SetURLVars(req, map[string]string{"id": "pkg-1"})

	rec := httptest.NewRecorder()
	server.handleDownloadEdgePackage(rec, req)

	assert.Equal(t, http.StatusUnauthorized, rec.Code)
}

func TestHandleRevokeEdgePackageSuccess(t *testing.T) {
	now := time.Now()
	service := &stubEdgeOnboardingService{
		revokeResult: &models.EdgeOnboardingRevokeResult{
			Package: &models.EdgeOnboardingPackage{
				PackageID:          "pkg-2",
				Label:              "Edge Poller",
				ComponentID:        "edge-poller",
				ComponentType:      models.EdgeOnboardingComponentTypePoller,
				PollerID:           "edge-poller",
				Status:             models.EdgeOnboardingStatusRevoked,
				DownstreamSPIFFEID: "spiffe://example.org/ns/edge/edge-poller",
				CreatedAt:          now,
				UpdatedAt:          now,
				RevokedAt:          &now,
			},
		},
	}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	body, _ := json.Marshal(edgePackageRevokeRequest{Reason: "compromised"})
	req := httptest.NewRequest(http.MethodPost, "/api/admin/edge-packages/pkg-2/revoke", bytes.NewReader(body))
	req = mux.SetURLVars(req, map[string]string{"id": "pkg-2"})
	req = req.WithContext(context.WithValue(req.Context(), auth.UserKey, &models.User{Email: "ops@example.com"}))

	rec := httptest.NewRecorder()
	server.handleRevokeEdgePackage(rec, req)

	resp := rec.Result()
	defer func() { _ = resp.Body.Close() }()

	require.Equal(t, http.StatusOK, resp.StatusCode)

	var payload edgePackageView
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&payload))
	assert.Equal(t, "pkg-2", payload.PackageID)
	assert.Equal(t, string(models.EdgeOnboardingStatusRevoked), payload.Status)

	require.NotNil(t, service.lastRevokeReq)
	assert.Equal(t, "pkg-2", service.lastRevokeReq.PackageID)
	assert.Equal(t, "compromised", service.lastRevokeReq.Reason)
	assert.Equal(t, "ops@example.com", service.lastRevokeReq.Actor)
	assert.Equal(t, "192.0.2.1", service.lastRevokeReq.SourceIP)
}

func TestHandleRevokeEdgePackageConflict(t *testing.T) {
	service := &stubEdgeOnboardingService{
		revokeErr: models.ErrEdgeOnboardingPackageRevoked,
	}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	req := httptest.NewRequest(http.MethodPost, "/api/admin/edge-packages/pkg-2/revoke", bytes.NewReader([]byte(`{}`)))
	req = mux.SetURLVars(req, map[string]string{"id": "pkg-2"})

	rec := httptest.NewRecorder()
	server.handleRevokeEdgePackage(rec, req)

	assert.Equal(t, http.StatusConflict, rec.Code)
}

func TestHandleDeleteEdgePackageSuccess(t *testing.T) {
	service := &stubEdgeOnboardingService{}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	req := httptest.NewRequest(http.MethodDelete, "/api/admin/edge-packages/pkg-9", nil)
	req = mux.SetURLVars(req, map[string]string{"id": "pkg-9"})

	rec := httptest.NewRecorder()
	server.handleDeleteEdgePackage(rec, req)

	assert.Equal(t, http.StatusNoContent, rec.Code)
	assert.Equal(t, "pkg-9", service.lastDeleteID)
}

func TestHandleDeleteEdgePackageInvalid(t *testing.T) {
	service := &stubEdgeOnboardingService{
		deleteErr: models.ErrEdgeOnboardingInvalidRequest,
	}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	req := httptest.NewRequest(http.MethodDelete, "/api/admin/edge-packages/pkg-2", nil)
	req = mux.SetURLVars(req, map[string]string{"id": "pkg-2"})

	rec := httptest.NewRecorder()
	server.handleDeleteEdgePackage(rec, req)

	assert.Equal(t, http.StatusBadRequest, rec.Code)
}

func TestHandleDeleteEdgePackageNotFound(t *testing.T) {
	service := &stubEdgeOnboardingService{
		deleteErr: db.ErrEdgePackageNotFound,
	}
	server := NewAPIServer(models.CORSConfig{}, WithEdgeOnboarding(service))

	req := httptest.NewRequest(http.MethodDelete, "/api/admin/edge-packages/pkg-404", nil)
	req = mux.SetURLVars(req, map[string]string{"id": "pkg-404"})

	rec := httptest.NewRecorder()
	server.handleDeleteEdgePackage(rec, req)

	assert.Equal(t, http.StatusNotFound, rec.Code)
}
