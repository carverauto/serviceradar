package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/pem"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/spireadmin"
)

type fakeSpireAdminClient struct {
	token     string
	tokenTTL  time.Duration
	entryID   string
	bundlePEM []byte
	deleteIDs []string
}

func newFakeSpireClient() *fakeSpireAdminClient {
	return &fakeSpireAdminClient{
		token:     "edge-token",
		tokenTTL:  10 * time.Minute,
		entryID:   "entry-edge",
		bundlePEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: []byte{0x01, 0x02, 0x03}}),
	}
}

func (f *fakeSpireAdminClient) CreateJoinToken(ctx context.Context, params spireadmin.JoinTokenParams) (*spireadmin.JoinTokenResult, error) {
	expires := time.Now().Add(f.tokenTTL)
	return &spireadmin.JoinTokenResult{
		Token:    f.token,
		Expires:  expires,
		ParentID: "spiffe://example.org/spire/agent/join_token/" + f.token,
	}, nil
}

func (f *fakeSpireAdminClient) CreateDownstreamEntry(ctx context.Context, params spireadmin.DownstreamEntryParams) (*spireadmin.DownstreamEntryResult, error) {
	return &spireadmin.DownstreamEntryResult{EntryID: f.entryID}, nil
}

func (f *fakeSpireAdminClient) FetchBundle(context.Context) ([]byte, error) {
	return f.bundlePEM, nil
}

func (f *fakeSpireAdminClient) DeleteEntry(ctx context.Context, entryID string) error {
	f.deleteIDs = append(f.deleteIDs, entryID)
	return nil
}

func (f *fakeSpireAdminClient) Close() error { return nil }

func validPollerMetadataJSON() string {
	return `{
		"core_address": "core:50052",
		"core_spiffe_id": "spiffe://example.org/ns/demo/sa/serviceradar-core",
		"spire_upstream_address": "spire.example.org",
		"spire_parent_id": "spiffe://example.org/spire/agent/upstream",
		"agent_spiffe_id": "spiffe://example.org/services/agent"
	}`
}

func TestEdgeOnboardingCreatePackageSuccess(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x11}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:          true,
		EncryptionKey:    encKey,
		DefaultSelectors: []string{"unix:uid:0"},
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	require.NotNil(t, svc)

	svc.refreshInterval = 0
	svc.SetAllowedPollerCallback(func([]string) {})
	require.NoError(t, svc.Start(context.Background()))
	defer func() { assert.NoError(t, svc.Stop(context.Background())) }()

	svc.now = func() time.Time { return time.Unix(1700000000, 0).UTC() }
	svc.rand = bytes.NewReader(bytes.Repeat([]byte{0x01}, 64))

	mockDB.EXPECT().ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).Return([]*models.EdgeOnboardingPackage{}, nil)
	mockDB.EXPECT().UpsertEdgeOnboardingPackage(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, pkg *models.EdgeOnboardingPackage) error {
		assert.Equal(t, "edge-poller", pkg.ComponentID)
		assert.Equal(t, "edge-poller", pkg.PollerID)
		assert.Equal(t, models.EdgeOnboardingComponentTypePoller, pkg.ComponentType)
		assert.Equal(t, models.EdgeOnboardingComponentTypeNone, pkg.ParentType)
		assert.Empty(t, pkg.ParentID)
		assert.Empty(t, pkg.CheckerKind)
		assert.Empty(t, pkg.CheckerConfigJSON)
		assert.Zero(t, pkg.KVRevision)
		assert.Equal(t, fakeSpire.entryID, pkg.DownstreamEntryID)
		assert.Equal(t, models.EdgeOnboardingStatusIssued, pkg.Status)
		assert.NotEmpty(t, pkg.JoinTokenCiphertext)
		assert.NotEmpty(t, pkg.BundleCiphertext)
		return nil
	})
	mockDB.EXPECT().InsertEdgeOnboardingEvent(gomock.Any(), gomock.Any()).Return(nil)

	result, err := svc.CreatePackage(context.Background(), &models.EdgeOnboardingCreateRequest{
		Label:        "Edge Poller",
		CreatedBy:    "admin@example.com",
		MetadataJSON: validPollerMetadataJSON(),
	})
	require.NoError(t, err)
	require.NotNil(t, result)

	assert.Equal(t, fakeSpire.token, result.JoinToken)
	assert.Equal(t, fakeSpire.entryID, result.DownstreamEntryID)
	assert.Equal(t, string(fakeSpire.bundlePEM), string(result.BundlePEM))
	assert.NotEmpty(t, result.DownloadToken)
	assert.Empty(t, fakeSpire.deleteIDs)

	assert.True(t, svc.isPollerAllowed(context.Background(), "edge-poller"))
}

func TestEdgeOnboardingCreatePackageMissingMetadata(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x99}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:          true,
		EncryptionKey:    encKey,
		DefaultSelectors: []string{"unix:uid:0"},
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	require.NotNil(t, svc)

	svc.refreshInterval = 0
	svc.SetAllowedPollerCallback(func([]string) {})
	require.NoError(t, svc.Start(context.Background()))
	defer func() { assert.NoError(t, svc.Stop(context.Background())) }()

	_, err = svc.CreatePackage(context.Background(), &models.EdgeOnboardingCreateRequest{
		Label:     "Edge Missing Metadata",
		CreatedBy: "admin@example.com",
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, models.ErrEdgeOnboardingInvalidRequest)
	assert.Contains(t, err.Error(), "metadata_json missing required key")
}

func TestEdgeOnboardingCreatePackagePollerUsesMetadataDefaults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	keyBytes := bytes.Repeat([]byte{0x33}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
		DefaultMetadata: map[string]map[string]string{
			"poller": {
				"core_address":           "core:50052",
				"core_spiffe_id":         "spiffe://example.org/ns/demo/sa/serviceradar-core",
				"spire_upstream_address": "spire.example.org",
				"spire_parent_id":        "spiffe://example.org/spire/agent/upstream",
				"agent_spiffe_id":        "spiffe://example.org/services/agent",
			},
		},
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	require.NotNil(t, svc)

	svc.refreshInterval = 0
	svc.SetAllowedPollerCallback(func([]string) {})
	require.NoError(t, svc.Start(context.Background()))
	defer func() { assert.NoError(t, svc.Stop(context.Background())) }()

	svc.now = func() time.Time { return time.Unix(1700000500, 0).UTC() }
	svc.rand = bytes.NewReader(bytes.Repeat([]byte{0x02}, 64))

	mockDB.EXPECT().ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).Return([]*models.EdgeOnboardingPackage{}, nil)
	mockDB.EXPECT().UpsertEdgeOnboardingPackage(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, pkg *models.EdgeOnboardingPackage) error {
		require.NotNil(t, pkg)
		assert.Equal(t, models.EdgeOnboardingComponentTypePoller, pkg.ComponentType)
		assert.NotEmpty(t, pkg.MetadataJSON)

		meta, err := parseEdgeMetadataMap(pkg.MetadataJSON)
		require.NoError(t, err)
		assert.Equal(t, "core:50052", meta["core_address"])
		assert.Equal(t, "spiffe://example.org/ns/demo/sa/serviceradar-core", meta["core_spiffe_id"])
		assert.Equal(t, "spire.example.org", meta["spire_upstream_address"])
		assert.Equal(t, "spiffe://example.org/spire/agent/upstream", meta["spire_parent_id"])
		assert.Equal(t, "spiffe://example.org/services/agent", meta["agent_spiffe_id"])

		return nil
	})
	mockDB.EXPECT().InsertEdgeOnboardingEvent(gomock.Any(), gomock.Any()).Return(nil)

	_, err = svc.CreatePackage(context.Background(), &models.EdgeOnboardingCreateRequest{
		Label:     "Default Metadata Poller",
		CreatedBy: "admin@example.com",
	})
	require.NoError(t, err)
}

func TestEdgeOnboardingCreatePackagePollerConflict(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x22}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	svc.refreshInterval = 0
	svc.SetAllowedPollerCallback(func([]string) {})
	require.NoError(t, svc.Start(context.Background()))
	defer func() { assert.NoError(t, svc.Stop(context.Background())) }()

	svc.rand = bytes.NewReader(bytes.Repeat([]byte{0xFF}, 64))

	mockDB.EXPECT().ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).Return([]*models.EdgeOnboardingPackage{{
		PollerID:      "edge-conflict",
		ComponentType: models.EdgeOnboardingComponentTypePoller,
	}}, nil)

	_, err = svc.CreatePackage(context.Background(), &models.EdgeOnboardingCreateRequest{
		Label:        "Edge Conflict",
		PollerID:     "edge-conflict",
		MetadataJSON: validPollerMetadataJSON(),
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, models.ErrEdgeOnboardingPollerConflict)
}

func TestEdgeOnboardingDeliverPackageSuccess(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x33}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	svc.refreshInterval = 0
	svc.SetAllowedPollerCallback(func([]string) {})
	require.NoError(t, svc.Start(context.Background()))
	defer func() { assert.NoError(t, svc.Stop(context.Background())) }()

	now := time.Unix(1710000000, 0).UTC()
	svc.now = func() time.Time { return now }

	joinCipher, err := svc.cipher.Encrypt([]byte("join-token"))
	require.NoError(t, err)
	bundleCipher, err := svc.cipher.Encrypt([]byte("bundle"))
	require.NoError(t, err)

	pkg := &models.EdgeOnboardingPackage{
		PackageID:              "pkg-1",
		Label:                  "Edge Poller",
		ComponentID:            "edge-poller",
		ComponentType:          models.EdgeOnboardingComponentTypePoller,
		ParentType:             models.EdgeOnboardingComponentTypeNone,
		ParentID:               "",
		PollerID:               "edge-poller",
		Status:                 models.EdgeOnboardingStatusIssued,
		DownstreamEntryID:      fakeSpire.entryID,
		DownstreamSPIFFEID:     "spiffe://example.org/ns/edge/edge-poller",
		JoinTokenCiphertext:    joinCipher,
		JoinTokenExpiresAt:     now.Add(5 * time.Minute),
		BundleCiphertext:       bundleCipher,
		DownloadTokenHash:      hashDownloadToken("download-token"),
		DownloadTokenExpiresAt: now.Add(30 * time.Minute),
		CreatedBy:              "ops@example.com",
		CreatedAt:              now.Add(-time.Hour),
		UpdatedAt:              now.Add(-time.Hour),
	}

	mockDB.EXPECT().GetEdgeOnboardingPackage(gomock.Any(), "pkg-1").Return(pkg, nil)
	mockDB.EXPECT().UpsertEdgeOnboardingPackage(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, stored *models.EdgeOnboardingPackage) error {
		assert.Equal(t, models.EdgeOnboardingStatusDelivered, stored.Status)
		assert.NotNil(t, stored.DeliveredAt)
		assert.Equal(t, now, stored.DeliveredAt.UTC())
		assert.Empty(t, stored.DownloadTokenHash)
		assert.Equal(t, now, stored.DownloadTokenExpiresAt)
		assert.Equal(t, now, stored.UpdatedAt)
		return nil
	})
	mockDB.EXPECT().InsertEdgeOnboardingEvent(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, event *models.EdgeOnboardingEvent) error {
		assert.Equal(t, "pkg-1", event.PackageID)
		assert.Equal(t, "delivered", event.EventType)
		assert.Equal(t, "ops@example.com", event.Actor)
		assert.Equal(t, "1.2.3.4", event.SourceIP)
		return nil
	})

	result, err := svc.DeliverPackage(context.Background(), &models.EdgeOnboardingDeliverRequest{
		PackageID:     "pkg-1",
		DownloadToken: "download-token",
		Actor:         " ops@example.com ",
		SourceIP:      "1.2.3.4",
	})
	require.NoError(t, err)
	require.NotNil(t, result)

	assert.Equal(t, "join-token", result.JoinToken)
	assert.Equal(t, []byte("bundle"), result.BundlePEM)
	assert.Equal(t, models.EdgeOnboardingStatusDelivered, result.Package.Status)
}

func TestEdgeOnboardingDeliverPackageInvalidToken(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x44}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	svc.refreshInterval = 0
	svc.SetAllowedPollerCallback(func([]string) {})
	require.NoError(t, svc.Start(context.Background()))
	defer func() { assert.NoError(t, svc.Stop(context.Background())) }()

	now := time.Unix(1710000000, 0).UTC()
	svc.now = func() time.Time { return now }

	joinCipher, err := svc.cipher.Encrypt([]byte("join-token"))
	require.NoError(t, err)
	bundleCipher, err := svc.cipher.Encrypt([]byte("bundle"))
	require.NoError(t, err)

	pkg := &models.EdgeOnboardingPackage{
		PackageID:              "pkg-1",
		ComponentID:            "edge-poller",
		ComponentType:          models.EdgeOnboardingComponentTypePoller,
		ParentType:             models.EdgeOnboardingComponentTypeNone,
		ParentID:               "",
		PollerID:               "edge-poller",
		Status:                 models.EdgeOnboardingStatusIssued,
		JoinTokenCiphertext:    joinCipher,
		JoinTokenExpiresAt:     now.Add(5 * time.Minute),
		BundleCiphertext:       bundleCipher,
		DownloadTokenHash:      hashDownloadToken("expected"),
		DownloadTokenExpiresAt: now.Add(time.Minute),
	}

	mockDB.EXPECT().GetEdgeOnboardingPackage(gomock.Any(), "pkg-1").Return(pkg, nil)

	_, err = svc.DeliverPackage(context.Background(), &models.EdgeOnboardingDeliverRequest{
		PackageID:     "pkg-1",
		DownloadToken: "wrong",
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, models.ErrEdgeOnboardingDownloadInvalid)
}

func TestEdgeOnboardingRevokePackageSuccess(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x55}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	firstCall := mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{"edge-poller"}, nil)
	secondCall := mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()
	gomock.InOrder(firstCall, secondCall)

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	svc.refreshInterval = 0
	svc.SetAllowedPollerCallback(func([]string) {})
	require.NoError(t, svc.Start(context.Background()))
	defer func() { assert.NoError(t, svc.Stop(context.Background())) }()

	now := time.Unix(1710000000, 0).UTC()
	svc.now = func() time.Time { return now }

	pkg := &models.EdgeOnboardingPackage{
		PackageID:              "pkg-2",
		ComponentID:            "edge-poller",
		ComponentType:          models.EdgeOnboardingComponentTypePoller,
		ParentType:             models.EdgeOnboardingComponentTypeNone,
		ParentID:               "",
		PollerID:               "edge-poller",
		Status:                 models.EdgeOnboardingStatusIssued,
		DownstreamEntryID:      "entry-edge",
		JoinTokenExpiresAt:     now.Add(time.Hour),
		DownloadTokenHash:      hashDownloadToken("token"),
		DownloadTokenExpiresAt: now.Add(time.Hour),
		CreatedAt:              now.Add(-time.Hour),
		UpdatedAt:              now.Add(-time.Hour),
	}

	mockDB.EXPECT().GetEdgeOnboardingPackage(gomock.Any(), "pkg-2").Return(pkg, nil)
	mockDB.EXPECT().UpsertEdgeOnboardingPackage(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, stored *models.EdgeOnboardingPackage) error {
		assert.Equal(t, models.EdgeOnboardingStatusRevoked, stored.Status)
		assert.NotNil(t, stored.RevokedAt)
		assert.Equal(t, now, stored.RevokedAt.UTC())
		assert.Empty(t, stored.DownloadTokenHash)
		assert.Equal(t, now, stored.DownloadTokenExpiresAt)
		assert.Equal(t, now, stored.JoinTokenExpiresAt)
		return nil
	})
	mockDB.EXPECT().InsertEdgeOnboardingEvent(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, event *models.EdgeOnboardingEvent) error {
		assert.Equal(t, "revoked", event.EventType)
		assert.Equal(t, "admin@example.com", event.Actor)
		assert.Equal(t, "10.0.0.1", event.SourceIP)
		return nil
	})

	result, err := svc.RevokePackage(context.Background(), &models.EdgeOnboardingRevokeRequest{
		PackageID: "pkg-2",
		Actor:     " admin@example.com ",
		Reason:    " rotated ",
		SourceIP:  "10.0.0.1",
	})
	require.NoError(t, err)
	require.NotNil(t, result)
	assert.Equal(t, models.EdgeOnboardingStatusRevoked, result.Package.Status)
	assert.Contains(t, fakeSpire.deleteIDs, "entry-edge")
	assert.False(t, svc.isPollerAllowed(context.Background(), "edge-poller"))
}

func TestEdgeOnboardingRevokePackageAlreadyRevoked(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x66}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	svc.refreshInterval = 0
	svc.SetAllowedPollerCallback(func([]string) {})
	require.NoError(t, svc.Start(context.Background()))
	defer func() { assert.NoError(t, svc.Stop(context.Background())) }()

	pkg := &models.EdgeOnboardingPackage{
		PackageID:         "pkg-3",
		ComponentID:       "edge-poller",
		ComponentType:     models.EdgeOnboardingComponentTypePoller,
		Status:            models.EdgeOnboardingStatusRevoked,
		DownstreamEntryID: "entry-edge",
	}

	mockDB.EXPECT().GetEdgeOnboardingPackage(gomock.Any(), "pkg-3").Return(pkg, nil)

	_, err = svc.RevokePackage(context.Background(), &models.EdgeOnboardingRevokeRequest{
		PackageID: "pkg-3",
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, models.ErrEdgeOnboardingPackageRevoked)
}

func TestEdgeOnboardingDeletePackageSuccess(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x88}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	svc.SetAllowedPollerCallback(func([]string) {})

	pkg := &models.EdgeOnboardingPackage{
		PackageID:     "pkg-del",
		Status:        models.EdgeOnboardingStatusRevoked,
		PollerID:      "edge-poller",
		ComponentType: models.EdgeOnboardingComponentTypePoller,
		UpdatedAt:     time.Date(2024, time.January, 2, 15, 3, 5, 0, time.UTC),
	}

	mockDB.EXPECT().GetEdgeOnboardingPackage(gomock.Any(), "pkg-del").Return(pkg, nil)

	deleteTime := time.Date(2024, time.January, 2, 15, 4, 5, 0, time.UTC)
	svc.now = func() time.Time { return deleteTime }

	mockDB.EXPECT().DeleteEdgeOnboardingPackage(gomock.Any(), gomock.AssignableToTypeOf(&models.EdgeOnboardingPackage{})).
		DoAndReturn(func(_ context.Context, updated *models.EdgeOnboardingPackage) error {
			assert.Equal(t, "pkg-del", updated.PackageID)
			assert.Equal(t, models.EdgeOnboardingStatusDeleted, updated.Status)
			require.NotNil(t, updated.DeletedAt)
			assert.Equal(t, deleteTime, updated.UpdatedAt)
			assert.WithinDuration(t, deleteTime, *updated.DeletedAt, time.Second)
			assert.Equal(t, "unknown", updated.DeletedBy)
			assert.Equal(t, "", updated.DeletedReason)
			return nil
		})

	mockDB.EXPECT().InsertEdgeOnboardingEvent(gomock.Any(), gomock.AssignableToTypeOf(&models.EdgeOnboardingEvent{})).
		DoAndReturn(func(_ context.Context, event *models.EdgeOnboardingEvent) error {
			assert.Equal(t, "pkg-del", event.PackageID)
			assert.Equal(t, "deleted", event.EventType)
			assert.WithinDuration(t, deleteTime, event.EventTime, time.Second)
			return nil
		})

	require.NoError(t, svc.DeletePackage(context.Background(), "pkg-del"))
}

func TestEdgeOnboardingDeletePackageBumpsTimestamp(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x8A}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	svc.SetAllowedPollerCallback(func([]string) {})

	prior := time.Date(2025, time.February, 3, 10, 11, 12, int(250*time.Millisecond), time.UTC)
	pkg := &models.EdgeOnboardingPackage{
		PackageID:     "pkg-del",
		Status:        models.EdgeOnboardingStatusRevoked,
		PollerID:      "edge-poller",
		ComponentType: models.EdgeOnboardingComponentTypePoller,
		UpdatedAt:     prior,
		RevokedAt:     &prior,
	}

	mockDB.EXPECT().GetEdgeOnboardingPackage(gomock.Any(), "pkg-del").Return(pkg, nil)

	// Force the service clock to a timestamp that would normally sort behind the existing revision.
	svc.now = func() time.Time { return prior.Add(-500 * time.Microsecond) }

	mockDB.EXPECT().DeleteEdgeOnboardingPackage(gomock.Any(), gomock.AssignableToTypeOf(&models.EdgeOnboardingPackage{})).
		DoAndReturn(func(_ context.Context, updated *models.EdgeOnboardingPackage) error {
			assert.Equal(t, "pkg-del", updated.PackageID)
			assert.Equal(t, models.EdgeOnboardingStatusDeleted, updated.Status)
			require.NotNil(t, updated.DeletedAt)
			assert.True(t, updated.UpdatedAt.After(prior))
			assert.WithinDuration(t, updated.UpdatedAt, *updated.DeletedAt, time.Millisecond)
			assert.Equal(t, "unknown", updated.DeletedBy)
			assert.Equal(t, "", updated.DeletedReason)
			return nil
		})

	mockDB.EXPECT().InsertEdgeOnboardingEvent(gomock.Any(), gomock.AssignableToTypeOf(&models.EdgeOnboardingEvent{})).
		Return(nil)

	require.NoError(t, svc.DeletePackage(context.Background(), "pkg-del"))
}

func TestEdgeOnboardingListPackagesTombstoneFiltering(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x8B}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	svc.SetAllowedPollerCallback(func([]string) {})

	tombstoneTime := time.Date(2025, time.March, 4, 18, 20, 0, 0, time.UTC)
	basePkg := &models.EdgeOnboardingPackage{
		PackageID:     "pkg-123",
		Status:        models.EdgeOnboardingStatusRevoked,
		UpdatedAt:     tombstoneTime,
		DeletedAt:     &tombstoneTime,
		DeletedBy:     "admin@example.org",
		ComponentType: models.EdgeOnboardingComponentTypePoller,
		PollerID:      "edge-poller",
	}

	mockDB.EXPECT().
		ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).
		Return([]*models.EdgeOnboardingPackage{basePkg}, nil).Times(2)

	// Default filter should hide deleted packages.
	result, err := svc.ListPackages(context.Background(), nil)
	require.NoError(t, err)
	require.Empty(t, result)

	// Explicitly request deleted status.
	filter := &models.EdgeOnboardingListFilter{
		Statuses: []models.EdgeOnboardingStatus{models.EdgeOnboardingStatusDeleted},
	}
	result, err = svc.ListPackages(context.Background(), filter)
	require.NoError(t, err)
	require.Len(t, result, 1)
	assert.Equal(t, models.EdgeOnboardingStatusDeleted, result[0].Status)
	require.NotNil(t, result[0].DeletedAt)
	assert.WithinDuration(t, tombstoneTime, *result[0].DeletedAt, time.Second)
	assert.Equal(t, tombstoneTime, result[0].UpdatedAt)
	assert.Equal(t, "admin@example.org", result[0].DeletedBy)
}

func TestEdgeOnboardingGetPackageTombstone(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x8C}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	svc.SetAllowedPollerCallback(func([]string) {})

	tombstoneTime := time.Date(2025, time.April, 11, 8, 30, 0, 0, time.UTC)

	basePkg := &models.EdgeOnboardingPackage{
		PackageID:     "pkg-999",
		Status:        models.EdgeOnboardingStatusRevoked,
		UpdatedAt:     tombstoneTime,
		DeletedAt:     &tombstoneTime,
		DeletedBy:     "admin@example.org",
		ComponentType: models.EdgeOnboardingComponentTypePoller,
		PollerID:      "edge-poller",
	}

	mockDB.EXPECT().GetEdgeOnboardingPackage(gomock.Any(), "pkg-999").Return(basePkg, nil)

	result, err := svc.GetPackage(context.Background(), "pkg-999")
	require.NoError(t, err)
	require.NotNil(t, result)
	assert.Equal(t, models.EdgeOnboardingStatusDeleted, result.Status)
	require.NotNil(t, result.DeletedAt)
	assert.WithinDuration(t, tombstoneTime, *result.DeletedAt, time.Second)
	assert.Equal(t, tombstoneTime, result.UpdatedAt)
	assert.Equal(t, "admin@example.org", result.DeletedBy)
}

func TestEdgeOnboardingDeletePackageRequiresRevoked(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x89}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	spireCfg := &models.SpireAdminConfig{ServerSPIFFEID: "spiffe://example.org/spire/server"}
	fakeSpire := newFakeSpireClient()

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	svc.SetAllowedPollerCallback(func([]string) {})

	pkg := &models.EdgeOnboardingPackage{
		PackageID:     "pkg-pending",
		Status:        models.EdgeOnboardingStatusIssued,
		PollerID:      "edge-poller",
		ComponentType: models.EdgeOnboardingComponentTypePoller,
	}

	mockDB.EXPECT().GetEdgeOnboardingPackage(gomock.Any(), "pkg-pending").Return(pkg, nil)

	err = svc.DeletePackage(context.Background(), "pkg-pending")
	require.Error(t, err)
	assert.ErrorIs(t, err, models.ErrEdgeOnboardingInvalidRequest)
}
