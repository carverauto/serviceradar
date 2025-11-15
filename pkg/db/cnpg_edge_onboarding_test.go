package db

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBuildEdgeOnboardingPackageArgs(t *testing.T) {
	now := time.Date(2025, time.July, 4, 12, 0, 0, 0, time.UTC)
	delivered := now.Add(10 * time.Minute)
	activated := now.Add(20 * time.Minute)
	revoked := now.Add(30 * time.Minute)
	deleted := now.Add(40 * time.Minute)
	ip := "203.0.113.10"
	lastSeen := "spiffe://agent/test"

	pkg := &models.EdgeOnboardingPackage{
		PackageID:              "33c687b4-900f-4b70-9c77-57bcf8a2275d",
		Label:                  "test",
		ComponentID:            "component-1",
		ComponentType:          models.EdgeOnboardingComponentTypePoller,
		ParentType:             models.EdgeOnboardingComponentTypeAgent,
		ParentID:               "parent-1",
		PollerID:               "poller-1",
		Site:                   "site-a",
		Status:                 models.EdgeOnboardingStatusActivated,
		DownstreamEntryID:      "entry-123",
		DownstreamSPIFFEID:     "spiffe://downstream",
		Selectors:              []string{"env:demo"},
		CheckerKind:            "rperf",
		CheckerConfigJSON:      `{"interval":10}`,
		JoinTokenCiphertext:    "ciphertext",
		JoinTokenExpiresAt:     now,
		BundleCiphertext:       "bundle",
		DownloadTokenHash:      "hash",
		DownloadTokenExpiresAt: now.Add(time.Hour),
		CreatedBy:              "user@example.com",
		CreatedAt:              now.Add(-time.Hour),
		UpdatedAt:              now,
		DeliveredAt:            &delivered,
		ActivatedAt:            &activated,
		ActivatedFromIP:        &ip,
		LastSeenSPIFFEID:       &lastSeen,
		RevokedAt:              &revoked,
		DeletedAt:              &deleted,
		DeletedBy:              "deleter",
		DeletedReason:          "cleanup",
		MetadataJSON:           `{"env":"demo"}`,
		KVRevision:             42,
		Notes:                  "note",
	}

	args, err := buildEdgeOnboardingPackageArgs(pkg)
	require.NoError(t, err)
	require.Len(t, args, 33)

	assert.Equal(t, pkg.Label, args[1])
	assert.Equal(t, pkg.ComponentID, args[2])
	assert.Equal(t, string(pkg.ComponentType), args[3])
	assert.Equal(t, pkg.PollerID, args[6])
	assert.Equal(t, pkg.Site, args[7])
	assert.Equal(t, string(pkg.Status), args[8])
	assert.Equal(t, pkg.DownstreamEntryID, args[9])
	assert.Equal(t, pkg.DownstreamSPIFFEID, args[10])
	assert.Equal(t, pkg.Selectors, args[11])
	assert.Equal(t, pkg.CheckerKind, args[12])

	assertJSONRawEquals(t, map[string]int{"interval": 10}, args[13])
	assert.Equal(t, pkg.JoinTokenCiphertext, args[14])
	assert.Equal(t, now.UTC(), args[15])
	assert.Equal(t, pkg.BundleCiphertext, args[16])
	assert.Equal(t, pkg.DownloadTokenHash, args[17])
	assert.Equal(t, pkg.DownloadTokenExpiresAt.UTC(), args[18])
	assert.Equal(t, pkg.CreatedBy, args[19])
	assert.Equal(t, pkg.CreatedAt.UTC(), args[20])
	assert.Equal(t, pkg.UpdatedAt.UTC(), args[21])
	assert.Equal(t, delivered.UTC(), args[22])
	assert.Equal(t, activated.UTC(), args[23])
	assert.Equal(t, ip, args[24])
	assert.Equal(t, lastSeen, args[25])
	assert.Equal(t, revoked.UTC(), args[26])
	assert.Equal(t, deleted.UTC(), args[27])
	assert.Equal(t, "deleter", args[28])
	assert.Equal(t, "cleanup", args[29])
	assertJSONRawEquals(t, map[string]string{"env": "demo"}, args[30])
	assert.Equal(t, int64(42), args[31])
	assert.Equal(t, pkg.Notes, args[32])
}

func TestBuildEdgeOnboardingPackageArgsMissingID(t *testing.T) {
	_, err := buildEdgeOnboardingPackageArgs(&models.EdgeOnboardingPackage{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "package id is required")
}

func TestBuildEdgeOnboardingEventArgs(t *testing.T) {
	now := time.Now()
	event := &models.EdgeOnboardingEvent{
		PackageID:   "33c687b4-900f-4b70-9c77-57bcf8a2275d",
		EventTime:   now,
		EventType:   "deliver",
		Actor:       "actor",
		SourceIP:    "192.0.2.1",
		DetailsJSON: `{"status":"ok"}`,
	}

	args, err := buildEdgeOnboardingEventArgs(event)
	require.NoError(t, err)
	require.Len(t, args, 6)

	assert.Equal(t, event.EventType, args[2])
	assert.Equal(t, "actor", args[3])
	assert.Equal(t, "192.0.2.1", args[4])
	assertJSONRawEquals(t, map[string]string{"status": "ok"}, args[5])
}

func assertJSONRawEquals(t *testing.T, expected interface{}, value interface{}) {
	t.Helper()

	raw, ok := value.(json.RawMessage)
	require.True(t, ok, "value is not json raw message")

	expectedBytes, err := json.Marshal(expected)
	require.NoError(t, err)

	assert.Equal(t, string(expectedBytes), string(raw))
}
