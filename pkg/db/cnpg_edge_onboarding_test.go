package db

import (
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errFakeEdgePkgRowScanMismatch    = errors.New("fake edge package row scan mismatch")
	errFakeEdgePkgRowUnexpectedType  = errors.New("unexpected type in fake edge package row")
	errFakeEdgePkgRowUnsupportedDest = errors.New("unsupported scan destination in fake edge package row")
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
		ComponentType:          models.EdgeOnboardingComponentTypeGateway,
		ParentType:             models.EdgeOnboardingComponentTypeAgent,
		ParentID:               "parent-1",
		GatewayID:               "gateway-1",
		Site:                   "site-a",
		Status:                 models.EdgeOnboardingStatusActivated,
		SecurityMode:           "mtls",
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
	require.Len(t, args, 34)

	assert.Equal(t, pkg.Label, args[1])
	assert.Equal(t, pkg.ComponentID, args[2])
	assert.Equal(t, string(pkg.ComponentType), args[3])
	assert.Equal(t, pkg.GatewayID, args[6])
	assert.Equal(t, pkg.Site, args[7])
	assert.Equal(t, pkg.SecurityMode, args[8])
	assert.Equal(t, string(pkg.Status), args[9])
	assert.Equal(t, pkg.DownstreamEntryID, args[10])
	assert.Equal(t, pkg.DownstreamSPIFFEID, args[11])
	assert.Equal(t, pkg.Selectors, args[12])
	assert.Equal(t, pkg.CheckerKind, args[13])

	assertJSONRawEquals(t, map[string]int{"interval": 10}, args[14])
	assert.Equal(t, pkg.JoinTokenCiphertext, args[15])
	assert.Equal(t, now.UTC(), args[16])
	assert.Equal(t, pkg.BundleCiphertext, args[17])
	assert.Equal(t, pkg.DownloadTokenHash, args[18])
	assert.Equal(t, pkg.DownloadTokenExpiresAt.UTC(), args[19])
	assert.Equal(t, pkg.CreatedBy, args[20])
	assert.Equal(t, pkg.CreatedAt.UTC(), args[21])
	assert.Equal(t, pkg.UpdatedAt.UTC(), args[22])
	assert.Equal(t, delivered.UTC(), args[23])
	assert.Equal(t, activated.UTC(), args[24])
	assert.Equal(t, ip, args[25])
	assert.Equal(t, lastSeen, args[26])
	assert.Equal(t, revoked.UTC(), args[27])
	assert.Equal(t, deleted.UTC(), args[28])
	assert.Equal(t, "deleter", args[29])
	assert.Equal(t, "cleanup", args[30])
	assertJSONRawEquals(t, map[string]string{"env": "demo"}, args[31])
	assert.Equal(t, int64(42), args[32])
	assert.Equal(t, pkg.Notes, args[33])
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

type fakeEdgePackageRow struct {
	values []interface{}
}

func (r *fakeEdgePackageRow) Scan(dest ...interface{}) error {
	if len(dest) != len(r.values) {
		return fmt.Errorf("%w: dest=%d values=%d", errFakeEdgePkgRowScanMismatch, len(dest), len(r.values))
	}

	for i, d := range dest {
		switch ptr := d.(type) {
		case *uuid.UUID:
			val, ok := r.values[i].(uuid.UUID)
			if !ok {
				return fmt.Errorf("%w: expected uuid.UUID at %d, got %T", errFakeEdgePkgRowUnexpectedType, i, r.values[i])
			}
			*ptr = val
		case *string:
			val, ok := r.values[i].(string)
			if !ok {
				return fmt.Errorf("%w: expected string at %d, got %T", errFakeEdgePkgRowUnexpectedType, i, r.values[i])
			}
			*ptr = val
		case *[]string:
			switch v := r.values[i].(type) {
			case []string:
				*ptr = append([]string(nil), v...)
			case nil:
				*ptr = nil
			default:
				return fmt.Errorf("%w: expected []string at %d, got %T", errFakeEdgePkgRowUnexpectedType, i, r.values[i])
			}
		case *[]byte:
			switch v := r.values[i].(type) {
			case []byte:
				*ptr = append([]byte(nil), v...)
			case string:
				*ptr = []byte(v)
			case nil:
				*ptr = nil
			default:
				return fmt.Errorf("%w: expected []byte at %d, got %T", errFakeEdgePkgRowUnexpectedType, i, r.values[i])
			}
		case *time.Time:
			val, ok := r.values[i].(time.Time)
			if !ok {
				return fmt.Errorf("%w: expected time.Time at %d, got %T", errFakeEdgePkgRowUnexpectedType, i, r.values[i])
			}
			*ptr = val
		case **time.Time:
			switch v := r.values[i].(type) {
			case *time.Time:
				*ptr = v
			case time.Time:
				t := v
				*ptr = &t
			case nil:
				*ptr = nil
			default:
				return fmt.Errorf("%w: expected *time.Time at %d, got %T", errFakeEdgePkgRowUnexpectedType, i, r.values[i])
			}
		case **string:
			switch v := r.values[i].(type) {
			case *string:
				*ptr = v
			case string:
				s := v
				*ptr = &s
			case nil:
				*ptr = nil
			default:
				return fmt.Errorf("%w: expected *string at %d, got %T", errFakeEdgePkgRowUnexpectedType, i, r.values[i])
			}
		case *int64:
			switch v := r.values[i].(type) {
			case int64:
				*ptr = v
			case uint64:
				*ptr = int64(v)
			default:
				return fmt.Errorf("%w: expected int64 at %d, got %T", errFakeEdgePkgRowUnexpectedType, i, r.values[i])
			}
		case *uint64:
			switch v := r.values[i].(type) {
			case uint64:
				*ptr = v
			case int64:
				*ptr = uint64(v)
			default:
				return fmt.Errorf("%w: expected uint64 at %d, got %T", errFakeEdgePkgRowUnexpectedType, i, r.values[i])
			}
		default:
			return fmt.Errorf("%w: %T at %d", errFakeEdgePkgRowUnsupportedDest, d, i)
		}
	}

	return nil
}

func TestScanEdgeOnboardingPackageIncludesSecurityMode(t *testing.T) {
	now := time.Date(2025, time.February, 1, 12, 0, 0, 0, time.UTC)
	delivered := now.Add(5 * time.Minute)
	activated := now.Add(10 * time.Minute)
	revoked := now.Add(20 * time.Minute)
	ip := "198.51.100.7"
	lastSeen := "spiffe://edge/sysmon"
	pkgID := uuid.New()

	row := &fakeEdgePackageRow{values: []interface{}{
		pkgID,
		"sysmon bundle",
		"sysmon-osx",
		"checker",
		"agent",
		"agent-1",
		"edge-gateway",
		"edge-site",
		"delivered",
		"mtls",
		"",
		"spiffe://downstream",
		[]string{"role:edge"},
		"sysmon",
		[]byte(`{"interval":30}`),
		"ciphertext",
		now,
		"bundle",
		"hash",
		now.Add(time.Hour),
		"creator@example.com",
		now.Add(-time.Hour),
		now,
		&delivered,
		&activated,
		&ip,
		&lastSeen,
		&revoked,
		(*time.Time)(nil),
		"deleter",
		"rotated",
		[]byte(`{"security_mode":"mtls","gateway_endpoint":"gateway:50053"}`),
		int64(7),
		"notes",
	}}

	pkg, err := scanEdgeOnboardingPackage(row)
	require.NoError(t, err)
	require.NotNil(t, pkg)

	assert.Equal(t, pkgID.String(), pkg.PackageID)
	assert.Equal(t, models.EdgeOnboardingComponentTypeChecker, pkg.ComponentType)
	assert.Equal(t, models.EdgeOnboardingComponentTypeAgent, pkg.ParentType)
	assert.Equal(t, models.EdgeOnboardingStatusDelivered, pkg.Status)
	assert.Equal(t, "mtls", pkg.SecurityMode)
	assert.Equal(t, []string{"role:edge"}, pkg.Selectors)
	assert.JSONEq(t, `{"security_mode":"mtls","gateway_endpoint":"gateway:50053"}`, pkg.MetadataJSON)
	assert.Equal(t, `{"interval":30}`, pkg.CheckerConfigJSON)
	require.NotNil(t, pkg.DeliveredAt)
	assert.WithinDuration(t, delivered, *pkg.DeliveredAt, time.Second)
	require.NotNil(t, pkg.ActivatedFromIP)
	assert.Equal(t, ip, *pkg.ActivatedFromIP)
	require.NotNil(t, pkg.LastSeenSPIFFEID)
	assert.Equal(t, lastSeen, *pkg.LastSeenSPIFFEID)
	assert.EqualValues(t, 7, pkg.KVRevision)
	assert.Equal(t, "notes", pkg.Notes)
}

func assertJSONRawEquals(t *testing.T, expected interface{}, value interface{}) {
	t.Helper()

	raw, ok := value.(json.RawMessage)
	require.True(t, ok, "value is not json raw message")

	expectedBytes, err := json.Marshal(expected)
	require.NoError(t, err)

	assert.Equal(t, string(expectedBytes), string(raw))
}
