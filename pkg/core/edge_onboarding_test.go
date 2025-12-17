package core

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding/mtls"
	testgrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/spireadmin"
	"github.com/carverauto/serviceradar/proto"
)

type fakeSpireAdminClient struct {
	token     string
	tokenTTL  time.Duration
	entryID   string
	bundlePEM []byte
	deleteIDs []string
}

var errListKeysConnectionFailed = errors.New("connection failed")

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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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
	require.ErrorIs(t, err, models.ErrEdgeOnboardingInvalidRequest)
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

func TestCreateMTLSPackageMintsClientCertificate(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x55}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	certDir := t.TempDir()
	require.NoError(t, testgrpc.GenerateTestCertificates(certDir))

	cfg := &models.EdgeOnboardingConfig{
		Enabled:         true,
		EncryptionKey:   encKey,
		MTLSCertBaseDir: certDir,
	}

	svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, nil, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	require.NotNil(t, svc)

	// Deterministic timestamps and download token source
	svc.now = func() time.Time { return time.Date(2025, time.January, 2, 3, 4, 5, 0, time.UTC) }
	svc.rand = bytes.NewReader(bytes.Repeat([]byte{0x01}, 128))

	mockDB.EXPECT().
		ListEdgeOnboardingPollerIDs(
			gomock.Any(),
			models.EdgeOnboardingStatusIssued,
			models.EdgeOnboardingStatusDelivered,
			models.EdgeOnboardingStatusActivated,
		).
		Return([]string{}, nil).
		AnyTimes()
	mockDB.EXPECT().ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).
		Return([]*models.EdgeOnboardingPackage{}, nil).
		AnyTimes()

	var storedPkg *models.EdgeOnboardingPackage
	mockDB.EXPECT().UpsertEdgeOnboardingPackage(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, pkg *models.EdgeOnboardingPackage) error {
		storedPkg = pkg
		return nil
	})

	result, err := svc.CreatePackage(context.Background(), &models.EdgeOnboardingCreateRequest{
		Label:         "sysmon mTLS",
		ComponentID:   "sysmon-osx",
		ComponentType: models.EdgeOnboardingComponentTypeChecker,
		ParentType:    models.EdgeOnboardingComponentTypeAgent,
		ParentID:      "agent-1",
		PollerID:      "edge-poller",
		CheckerKind:   "sysmon",
		SecurityMode:  "mtls",
		CreatedBy:     "admin@example.com",
		MetadataJSON: `{
			"security_mode":"mtls",
			"poller_endpoint":"poller.serviceradar:50053",
			"core_endpoint":"core:50052",
			"checker_endpoint":"192.168.2.134:50083",
			"server_name":"poller.serviceradar"
		}`,
	})
	require.NoError(t, err)
	require.NotNil(t, result)

	require.NotEmpty(t, result.DownloadToken)
	assert.Empty(t, result.JoinToken)
	require.NotNil(t, result.MTLSBundle)

	var bundle mtls.Bundle
	require.NoError(t, json.Unmarshal(result.MTLSBundle, &bundle))
	assert.Equal(t, "poller.serviceradar", bundle.ServerName)
	assert.Equal(t, "poller.serviceradar:50053", bundle.Endpoints["poller"])
	assert.Equal(t, "core:50052", bundle.Endpoints["core"])

	generatedAt, err := time.Parse(time.RFC3339, bundle.GeneratedAt)
	require.NoError(t, err)
	expiresAt, err := time.Parse(time.RFC3339, bundle.ExpiresAt)
	require.NoError(t, err)
	assert.Equal(t, svc.now(), generatedAt)
	assert.Equal(t, svc.now().Add(defaultMTLSCertTTL), expiresAt)

	// Validate the client certificate is signed by the generated CA
	caPEM, err := os.ReadFile(filepath.Join(certDir, "root.pem"))
	require.NoError(t, err)
	caBlock, _ := pem.Decode(caPEM)
	require.NotNil(t, caBlock)
	caCert, err := x509.ParseCertificate(caBlock.Bytes)
	require.NoError(t, err)

	clientBlock, _ := pem.Decode([]byte(bundle.ClientCert))
	require.NotNil(t, clientBlock)
	clientCert, err := x509.ParseCertificate(clientBlock.Bytes)
	require.NoError(t, err)
	require.NoError(t, clientCert.CheckSignatureFrom(caCert))
	assert.Equal(t, "sysmon-osx", clientCert.Subject.CommonName)
	expectedIP := net.ParseIP("192.168.2.134")
	foundExpected := false
	for _, ip := range clientCert.IPAddresses {
		if ip.Equal(expectedIP) {
			foundExpected = true
			break
		}
	}
	assert.True(t, foundExpected)

	// Stored package contains the encrypted bundle and mTLS security mode
	require.NotNil(t, storedPkg)
	assert.Equal(t, securityModeMTLS, storedPkg.SecurityMode)
	assert.Empty(t, storedPkg.JoinTokenCiphertext)
	assert.NotEmpty(t, storedPkg.BundleCiphertext)
	assert.Equal(t, models.EdgeOnboardingStatusIssued, storedPkg.Status)

	decrypted, err := svc.cipher.Decrypt(storedPkg.BundleCiphertext)
	require.NoError(t, err)
	assert.JSONEq(t, string(result.MTLSBundle), string(decrypted))
}

func TestCreateMTLSPackageRejectsCAPathTraversal(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x77}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	certDir := t.TempDir()
	require.NoError(t, testgrpc.GenerateTestCertificates(certDir))

	cfg := &models.EdgeOnboardingConfig{
		Enabled:         true,
		EncryptionKey:   encKey,
		MTLSCertBaseDir: certDir,
	}

	svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, nil, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	mockDB.EXPECT().
		ListEdgeOnboardingPollerIDs(
			gomock.Any(),
			models.EdgeOnboardingStatusIssued,
			models.EdgeOnboardingStatusDelivered,
			models.EdgeOnboardingStatusActivated,
		).
		Return([]string{}, nil).
		AnyTimes()
	mockDB.EXPECT().ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).
		Return([]*models.EdgeOnboardingPackage{}, nil).
		AnyTimes()

	_, err = svc.CreatePackage(context.Background(), &models.EdgeOnboardingCreateRequest{
		Label:         "sysmon mTLS traversal",
		ComponentID:   "sysmon-1",
		ComponentType: models.EdgeOnboardingComponentTypeChecker,
		ParentType:    models.EdgeOnboardingComponentTypeAgent,
		ParentID:      "agent-1",
		PollerID:      "edge-poller",
		CheckerKind:   "sysmon",
		SecurityMode:  "mtls",
		CreatedBy:     "admin@example.com",
		MetadataJSON: `{
			"security_mode":"mtls",
			"cert_dir":"/etc",
			"ca_cert_path":"/etc/shadow",
			"ca_key_path":"/etc/shadow"
		}`,
	})
	require.Error(t, err)
	require.ErrorIs(t, err, models.ErrEdgeOnboardingInvalidRequest)
	require.ErrorIs(t, err, ErrPathOutsideAllowedDir)
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

func TestEdgeOnboardingDeliverPackageDecryptErrorClassified(t *testing.T) {
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	now := time.Unix(1710000000, 0).UTC()
	svc.now = func() time.Time { return now }

	pkg := &models.EdgeOnboardingPackage{
		PackageID:              "pkg-1",
		ComponentID:            "edge-checker",
		ComponentType:          models.EdgeOnboardingComponentTypeChecker,
		ParentType:             models.EdgeOnboardingComponentTypeAgent,
		ParentID:               "agent-1",
		PollerID:               "edge-poller",
		Status:                 models.EdgeOnboardingStatusIssued,
		SecurityMode:           "mtls",
		MetadataJSON:           `{"security_mode":"mtls"}`,
		BundleCiphertext:       "not-base64",
		DownloadTokenHash:      hashDownloadToken("download-token"),
		DownloadTokenExpiresAt: now.Add(time.Minute),
		JoinTokenExpiresAt:     now.Add(time.Minute),
	}

	mockDB.EXPECT().GetEdgeOnboardingPackage(gomock.Any(), "pkg-1").Return(pkg, nil)

	_, err = svc.DeliverPackage(context.Background(), &models.EdgeOnboardingDeliverRequest{
		PackageID:     "pkg-1",
		DownloadToken: "download-token",
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, models.ErrEdgeOnboardingDecryptFailed)
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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
			assert.Equal(t, statusUnknown, updated.DeletedBy)
			assert.Empty(t, updated.DeletedReason)
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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
			assert.Equal(t, statusUnknown, updated.DeletedBy)
			assert.Empty(t, updated.DeletedReason)
			return nil
		})

	mockDB.EXPECT().InsertEdgeOnboardingEvent(gomock.Any(), gomock.AssignableToTypeOf(&models.EdgeOnboardingEvent{})).
		Return(nil)

	require.NoError(t, svc.DeletePackage(context.Background(), "pkg-del"))
}

func TestEdgeOnboardingRecordActivationPromotesStatus(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x99}, 32)
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	seenAt := time.Date(2025, time.October, 31, 2, 30, 0, 0, time.UTC)

	pkg := &models.EdgeOnboardingPackage{
		PackageID:     "pkg-activate",
		ComponentID:   "edge-poller",
		ComponentType: models.EdgeOnboardingComponentTypePoller,
		PollerID:      "edge-poller",
		Status:        models.EdgeOnboardingStatusDelivered,
		UpdatedAt:     seenAt.Add(-time.Minute),
	}

	mockDB.EXPECT().ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, filter *models.EdgeOnboardingListFilter) ([]*models.EdgeOnboardingPackage, error) {
			require.NotNil(t, filter)
			assert.Equal(t, "edge-poller", filter.PollerID)
			assert.Equal(t, 1, filter.Limit)
			assert.ElementsMatch(t, []models.EdgeOnboardingComponentType{models.EdgeOnboardingComponentTypePoller}, filter.Types)
			assert.ElementsMatch(t, []models.EdgeOnboardingStatus{
				models.EdgeOnboardingStatusIssued,
				models.EdgeOnboardingStatusDelivered,
				models.EdgeOnboardingStatusActivated,
			}, filter.Statuses)
			return []*models.EdgeOnboardingPackage{pkg}, nil
		})

	mockDB.EXPECT().UpsertEdgeOnboardingPackage(gomock.Any(), gomock.AssignableToTypeOf(&models.EdgeOnboardingPackage{})).
		DoAndReturn(func(_ context.Context, updated *models.EdgeOnboardingPackage) error {
			assert.Equal(t, models.EdgeOnboardingStatusActivated, updated.Status)
			require.NotNil(t, updated.ActivatedAt)
			assert.WithinDuration(t, seenAt, *updated.ActivatedAt, time.Second)
			require.NotNil(t, updated.ActivatedFromIP)
			assert.Equal(t, "203.0.113.7", *updated.ActivatedFromIP)
			assert.Equal(t, seenAt, updated.UpdatedAt)
			return nil
		})

	mockDB.EXPECT().InsertEdgeOnboardingEvent(gomock.Any(), gomock.AssignableToTypeOf(&models.EdgeOnboardingEvent{})).
		DoAndReturn(func(_ context.Context, evt *models.EdgeOnboardingEvent) error {
			assert.Equal(t, "pkg-activate", evt.PackageID)
			assert.Equal(t, "activated", evt.EventType)
			assert.Equal(t, "core", evt.Actor)
			assert.Equal(t, "203.0.113.7", evt.SourceIP)
			assert.WithinDuration(t, seenAt, evt.EventTime, time.Second)
			return nil
		})

	err = svc.RecordActivation(context.Background(), models.EdgeOnboardingComponentTypePoller, "edge-poller", "edge-poller", "203.0.113.7", "", seenAt)
	require.NoError(t, err)
}

func TestEdgeOnboardingRecordActivationNoopForActivatedAgent(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x5a}, 32)
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	activatedAt := time.Date(2025, time.October, 31, 2, 15, 0, 0, time.UTC)
	pkg := &models.EdgeOnboardingPackage{
		PackageID:         "pkg-agent",
		ComponentID:       "edge-agent",
		ComponentType:     models.EdgeOnboardingComponentTypeAgent,
		PollerID:          "edge-poller",
		Status:            models.EdgeOnboardingStatusActivated,
		ActivatedAt:       &activatedAt,
		ActivatedFromIP:   strPtr("203.0.113.7"),
		LastSeenSPIFFEID:  strPtr("spiffe://example.org/ns/edge/edge-agent"),
		UpdatedAt:         activatedAt,
		DownstreamEntryID: "entry-agent",
	}

	mockDB.EXPECT().ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, filter *models.EdgeOnboardingListFilter) ([]*models.EdgeOnboardingPackage, error) {
			require.NotNil(t, filter)
			assert.Equal(t, "edge-agent", filter.ComponentID)
			assert.Equal(t, 1, filter.Limit)
			assert.ElementsMatch(t, []models.EdgeOnboardingComponentType{models.EdgeOnboardingComponentTypeAgent}, filter.Types)
			return []*models.EdgeOnboardingPackage{pkg}, nil
		})

	err = svc.RecordActivation(context.Background(), models.EdgeOnboardingComponentTypeAgent, "edge-agent", "edge-poller", "203.0.113.7", "spiffe://example.org/ns/edge/edge-agent", activatedAt.Add(10*time.Minute))
	require.NoError(t, err)
}

func TestEdgeOnboardingRecordActivationUsesCache(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x21}, 32)
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	baseTime := time.Date(2025, time.November, 4, 5, 0, 0, 0, time.UTC)
	svc.activationCacheTTL = time.Hour
	svc.now = func() time.Time { return baseTime }

	pkg := &models.EdgeOnboardingPackage{
		PackageID:     "pkg-cache",
		ComponentID:   "edge-poller",
		ComponentType: models.EdgeOnboardingComponentTypePoller,
		PollerID:      "edge-poller",
		Status:        models.EdgeOnboardingStatusDelivered,
		UpdatedAt:     baseTime.Add(-time.Minute),
	}

	mockDB.EXPECT().ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).
		Return([]*models.EdgeOnboardingPackage{pkg}, nil).Times(1)

	mockDB.EXPECT().UpsertEdgeOnboardingPackage(gomock.Any(), gomock.AssignableToTypeOf(&models.EdgeOnboardingPackage{})).
		DoAndReturn(func(_ context.Context, updated *models.EdgeOnboardingPackage) error {
			assert.Equal(t, "pkg-cache", updated.PackageID)
			assert.Equal(t, models.EdgeOnboardingStatusActivated, updated.Status)
			require.NotNil(t, updated.ActivatedAt)
			assert.WithinDuration(t, baseTime, *updated.ActivatedAt, time.Second)
			require.NotNil(t, updated.ActivatedFromIP)
			assert.Equal(t, "198.51.100.5", *updated.ActivatedFromIP)
			return nil
		}).Times(1)

	mockDB.EXPECT().InsertEdgeOnboardingEvent(gomock.Any(), gomock.AssignableToTypeOf(&models.EdgeOnboardingEvent{})).
		Return(nil).Times(1)

	require.NoError(t, svc.RecordActivation(context.Background(), models.EdgeOnboardingComponentTypePoller, "edge-poller", "edge-poller", "198.51.100.5", "", baseTime))

	// Second activation should be satisfied entirely from cache – no additional DB expectations needed.
	err = svc.RecordActivation(context.Background(), models.EdgeOnboardingComponentTypePoller, "edge-poller", "edge-poller", "198.51.100.5", "", baseTime.Add(30*time.Second))
	require.NoError(t, err)

	stats := svc.ActivationCacheStats()
	assert.Equal(t, 1, stats.Size)
	assert.EqualValues(t, 2, stats.Lookups)
	assert.EqualValues(t, 1, stats.Hits)
	assert.EqualValues(t, 0, stats.NegativeHits)
	assert.EqualValues(t, 1, stats.Misses)
	assert.EqualValues(t, 0, stats.StaleEvicted)
}

func TestEdgeOnboardingRecordActivationCachesMisses(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0x2A}, 32)
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	baseTime := time.Date(2025, time.November, 4, 6, 0, 0, 0, time.UTC)
	svc.activationCacheTTL = time.Hour
	svc.now = func() time.Time { return baseTime }

	mockDB.EXPECT().ListEdgeOnboardingPackages(gomock.Any(), gomock.Any()).
		Return(nil, nil).Times(1)

	err = svc.RecordActivation(context.Background(), models.EdgeOnboardingComponentTypeAgent, "missing-agent", "edge-poller", "198.51.100.6", "", baseTime)
	require.NoError(t, err)

	// Second call should reuse the cached miss and avoid additional database lookups.
	err = svc.RecordActivation(context.Background(), models.EdgeOnboardingComponentTypeAgent, "missing-agent", "edge-poller", "198.51.100.6", "", baseTime.Add(10*time.Second))
	require.NoError(t, err)

	stats := svc.ActivationCacheStats()
	assert.Equal(t, 1, stats.Size)
	assert.EqualValues(t, 2, stats.Lookups)
	assert.EqualValues(t, 0, stats.Hits)
	assert.EqualValues(t, 1, stats.NegativeHits)
	assert.EqualValues(t, 1, stats.Misses)
	assert.EqualValues(t, 0, stats.StaleEvicted)
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

	svc, err := newEdgeOnboardingService(cfg, spireCfg, fakeSpire, mockDB, nil, nil, nil, logger.NewTestLogger())
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

func strPtr(value string) *string {
	return &value
}

// fakeKVClient is a test implementation of proto.KVServiceClient
type fakeKVClient struct {
	listKeysKeys []string
	listKeysErr  error
	lastPrefix   string
	getFn        func(key string) *proto.GetResponse
}

func (f *fakeKVClient) Get(ctx context.Context, in *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error) {
	if f.getFn != nil {
		if resp := f.getFn(in.GetKey()); resp != nil {
			return resp, nil
		}
	}
	return &proto.GetResponse{}, nil
}

func (f *fakeKVClient) BatchGet(ctx context.Context, in *proto.BatchGetRequest, opts ...grpc.CallOption) (*proto.BatchGetResponse, error) {
	return nil, nil
}

func (f *fakeKVClient) Put(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error) {
	return nil, nil
}

func (f *fakeKVClient) PutIfAbsent(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error) {
	return nil, nil
}

func (f *fakeKVClient) PutMany(ctx context.Context, in *proto.PutManyRequest, opts ...grpc.CallOption) (*proto.PutManyResponse, error) {
	return nil, nil
}

func (f *fakeKVClient) Update(ctx context.Context, in *proto.UpdateRequest, opts ...grpc.CallOption) (*proto.UpdateResponse, error) {
	return nil, nil
}

func (f *fakeKVClient) Delete(ctx context.Context, in *proto.DeleteRequest, opts ...grpc.CallOption) (*proto.DeleteResponse, error) {
	return nil, nil
}

func (f *fakeKVClient) Watch(ctx context.Context, in *proto.WatchRequest, opts ...grpc.CallOption) (grpc.ServerStreamingClient[proto.WatchResponse], error) {
	return nil, nil
}

func (f *fakeKVClient) Info(ctx context.Context, in *proto.InfoRequest, opts ...grpc.CallOption) (*proto.InfoResponse, error) {
	return nil, nil
}

func (f *fakeKVClient) ListKeys(ctx context.Context, in *proto.ListKeysRequest, opts ...grpc.CallOption) (*proto.ListKeysResponse, error) {
	f.lastPrefix = in.GetPrefix()
	if f.listKeysErr != nil {
		return nil, f.listKeysErr
	}
	return &proto.ListKeysResponse{Keys: f.listKeysKeys}, nil
}

func TestEdgeOnboardingFetchCheckerTemplate(t *testing.T) {
	testCases := []struct {
		name         string
		kvFactory    func() *fakeKVClient
		expectedKey  string
		expectedBody string
	}{
		{
			name: "prefers security mode",
			kvFactory: func() *fakeKVClient {
				return &fakeKVClient{
					getFn: func(key string) *proto.GetResponse {
						switch key {
						case "templates/checkers/mtls/sysmon.json":
							return &proto.GetResponse{Found: true, Value: []byte(`{"a":"b"}`)}
						default:
							return &proto.GetResponse{Found: false}
						}
					},
				}
			},
			expectedKey:  "templates/checkers/mtls/sysmon.json",
			expectedBody: `{"a":"b"}`,
		},
		{
			name: "falls back to spire",
			kvFactory: func() *fakeKVClient {
				return &fakeKVClient{
					getFn: func(key string) *proto.GetResponse {
						switch key {
						case "templates/checkers/sysmon.json":
							return &proto.GetResponse{Found: true, Value: []byte(`{"spire":true}`)}
						default:
							return &proto.GetResponse{Found: false}
						}
					},
				}
			},
			expectedKey:  "templates/checkers/sysmon.json",
			expectedBody: `{"spire":true}`,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)
			encKey := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xA6}, 32))

			cfg := &models.EdgeOnboardingConfig{
				Enabled:       true,
				EncryptionKey: encKey,
			}

			mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
				gomock.Any(),
				models.EdgeOnboardingStatusIssued,
				models.EdgeOnboardingStatusDelivered,
				models.EdgeOnboardingStatusActivated,
			).Return([]string{}, nil).AnyTimes()

			fakeKV := tc.kvFactory()

			svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, fakeKV, nil, nil, logger.NewTestLogger())
			require.NoError(t, err)

			key, body, err := svc.fetchCheckerTemplate(context.Background(), &models.EdgeOnboardingPackage{
				CheckerKind:   "sysmon",
				SecurityMode:  "mtls",
				ComponentType: models.EdgeOnboardingComponentTypeChecker,
			})
			require.NoError(t, err)
			assert.Equal(t, tc.expectedKey, key)
			assert.JSONEq(t, tc.expectedBody, body)
		})
	}
}

func TestEdgeOnboardingFetchCheckerTemplateMissing(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0xA8}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	fakeKV := &fakeKVClient{
		getFn: func(key string) *proto.GetResponse {
			_ = key
			return &proto.GetResponse{Found: false}
		},
	}

	svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, fakeKV, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	_, _, err = svc.fetchCheckerTemplate(context.Background(), &models.EdgeOnboardingPackage{
		CheckerKind:   "sysmon",
		SecurityMode:  "mtls",
		ComponentType: models.EdgeOnboardingComponentTypeChecker,
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no template found")
}

func TestSubstituteTemplateVariablesMTLSPlaceholders(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xAA}, 32)),
	}

	svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, &fakeKVClient{}, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)

	template := `{
	  "listen_addr": "0.0.0.0:50083",
	  "security": {
	    "mode": "mtls",
	    "cert_dir": "{{CERT_DIR}}",
	    "server_name": "{{SERVER_NAME}}",
	    "tls": {
	      "cert_file": "{{CERT_DIR}}/{{CLIENT_CERT_NAME}}.pem",
	      "key_file": "{{CERT_DIR}}/{{CLIENT_CERT_NAME}}-key.pem",
	      "ca_file": "{{CERT_DIR}}/root.pem",
	      "client_ca_file": "{{CERT_DIR}}/root.pem"
	    }
	  }
	}`

	pkg := &models.EdgeOnboardingPackage{
		ComponentType: models.EdgeOnboardingComponentTypeChecker,
		ComponentID:   "checker-1",
		ParentID:      "agent-1",
		CheckerKind:   "sysmon",
		SecurityMode:  "mtls",
		MetadataJSON:  `{"cert_dir":"/etc/custom","server_name":"custom.serviceradar","client_cert_name":"sysmon-client"}`,
	}

	out, err := svc.substituteTemplateVariables(template, pkg)
	require.NoError(t, err)

	var parsed map[string]interface{}
	require.NoError(t, json.Unmarshal([]byte(out), &parsed))

	sec := parsed["security"].(map[string]interface{})
	assert.Equal(t, "mtls", sec["mode"])
	assert.Equal(t, "/etc/custom", sec["cert_dir"])
	assert.Equal(t, "custom.serviceradar", sec["server_name"])

	tls := sec["tls"].(map[string]interface{})
	assert.Equal(t, "/etc/custom/sysmon-client.pem", tls["cert_file"])
	assert.Equal(t, "/etc/custom/sysmon-client-key.pem", tls["key_file"])
	assert.Equal(t, "/etc/custom/root.pem", tls["ca_file"])
	assert.Equal(t, "/etc/custom/root.pem", tls["client_ca_file"])
}

func TestEdgeOnboardingListComponentTemplatesNoKVClient(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0xA1}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	// Create service without KV client
	svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, nil, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	require.NotNil(t, svc)

	templates, err := svc.ListComponentTemplates(context.Background(), models.EdgeOnboardingComponentTypeChecker, "spire")
	require.Error(t, err)
	assert.Nil(t, templates)
	assert.ErrorIs(t, err, errKVClientUnavailable)
}

func TestEdgeOnboardingListComponentTemplatesEmpty(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0xA2}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	fakeKV := &fakeKVClient{listKeysKeys: []string{}}

	svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, fakeKV, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	require.NotNil(t, svc)

	templates, err := svc.ListComponentTemplates(context.Background(), models.EdgeOnboardingComponentTypeChecker, "spire")
	require.NoError(t, err)
	assert.Empty(t, templates)
	assert.Equal(t, "templates/checkers/", fakeKV.lastPrefix)
}

func TestEdgeOnboardingListComponentTemplatesSuccess(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0xA3}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	fakeKV := &fakeKVClient{
		listKeysKeys: []string{
			"templates/checkers/mtls/sysmon.json",
			"templates/checkers/mtls/snmp.json",
			"templates/checkers/mtls/rperf.json",
			"templates/checkers/mtls/dusk.json",
			"templates/checkers/mtls/sysmon-osx.json",
		},
	}

	svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, fakeKV, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	require.NotNil(t, svc)

	templates, err := svc.ListComponentTemplates(context.Background(), models.EdgeOnboardingComponentTypeChecker, "mtls")
	require.NoError(t, err)
	require.Len(t, templates, 5)
	assert.Equal(t, "templates/checkers/mtls/", fakeKV.lastPrefix)

	// Verify each template
	kinds := make(map[string]bool)
	for _, tmpl := range templates {
		kinds[tmpl.Kind] = true
		assert.Equal(t, "mtls", tmpl.SecurityMode)
		assert.Equal(t, "checker", string(tmpl.ComponentType))
		assert.Equal(t, "templates/checkers/mtls/"+tmpl.Kind+".json", tmpl.TemplateKey)
	}

	assert.True(t, kinds["sysmon"])
	assert.True(t, kinds["snmp"])
	assert.True(t, kinds["rperf"])
	assert.True(t, kinds["dusk"])
	assert.True(t, kinds["sysmon-osx"])
}

func TestEdgeOnboardingListComponentTemplatesFiltersInvalidKeys(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0xA4}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	fakeKV := &fakeKVClient{
		listKeysKeys: []string{
			"templates/checkers/mtls/sysmon.json",     // valid
			"templates/checkers/mtls/snmp.json",       // valid
			"templates/checkers/mtls/.json",           // invalid - empty kind
			"templates/checkers/mtls/test.yaml",       // invalid - not .json
			"other/prefix/sysmon.json",                // invalid - wrong prefix
			"templates/checkers/mtls/",                // invalid - no filename
			"templates/checkers/mtls/sub/nested.json", // valid - nested path treated as kind "sub/nested"
		},
	}

	svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, fakeKV, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	require.NotNil(t, svc)

	templates, err := svc.ListComponentTemplates(context.Background(), models.EdgeOnboardingComponentTypeChecker, "mtls")
	require.NoError(t, err)

	// Should only include valid templates
	require.Len(t, templates, 3)

	kinds := make(map[string]bool)
	for _, tmpl := range templates {
		kinds[tmpl.Kind] = true
	}

	assert.True(t, kinds["sysmon"])
	assert.True(t, kinds["snmp"])
	assert.True(t, kinds["sub/nested"]) // nested paths are allowed
	assert.False(t, kinds["test"])      // .yaml file excluded
	assert.False(t, kinds[""])          // empty kind excluded
}

func TestEdgeOnboardingListComponentTemplatesKVError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	keyBytes := bytes.Repeat([]byte{0xA5}, 32)
	encKey := base64.StdEncoding.EncodeToString(keyBytes)

	cfg := &models.EdgeOnboardingConfig{
		Enabled:       true,
		EncryptionKey: encKey,
	}

	mockDB.EXPECT().ListEdgeOnboardingPollerIDs(
		gomock.Any(),
		models.EdgeOnboardingStatusIssued,
		models.EdgeOnboardingStatusDelivered,
		models.EdgeOnboardingStatusActivated,
	).Return([]string{}, nil).AnyTimes()

	fakeKV := &fakeKVClient{
		listKeysErr: errListKeysConnectionFailed,
	}

	svc, err := newEdgeOnboardingService(cfg, nil, nil, mockDB, fakeKV, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	require.NotNil(t, svc)

	templates, err := svc.ListComponentTemplates(context.Background(), models.EdgeOnboardingComponentTypeChecker, "mtls")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "failed to list checker templates")
	assert.Contains(t, err.Error(), "connection failed")
	assert.Nil(t, templates)
}
