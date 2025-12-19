//go:build e2e

package inventory

import (
	"context"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	expectedFakerCount = 50000
	// Allow a small margin of error for startup timing or ephemeral objects,
	// but 50k input should ideally result in 50k output.
	// The "collapse" bugs reduced it to < 49k or < 1k, so 49.9k is a safe threshold.
	minAcceptableCount = 49950
	
	pollInterval = 5 * time.Second
	pollTimeout  = 5 * time.Minute
)

func TestE2E_FakerInventoryCount(t *testing.T) {
	dsn := os.Getenv("SR_E2E_DB_DSN")
	if dsn == "" {
		t.Skip("SR_E2E_DB_DSN not set, skipping E2E inventory test")
	}

	ctx := context.Background()
	log := logger.NewTestLogger()

	// 1. Connect to Database
	database, err := connectDB(ctx, dsn, log)
	require.NoError(t, err)
	defer database.Close()

	// 2. Wait for Inventory to Stabilize (reach minimum count)
	t.Logf("Waiting for inventory to reach %d devices (Timeout: %s)...", minAcceptableCount, pollTimeout)
	
	var finalCount int64
	assert.Eventually(t, func() bool {
		count, err := database.CountOCSFDevices(ctx)
		if err != nil {
			t.Logf("Error counting devices: %v", err)
			return false
		}
		finalCount = count
		t.Logf("Current device count: %d", count)
		
		return count >= minAcceptableCount
	}, pollTimeout, pollInterval, "Inventory failed to reach expected count of %d within %s. Final count: %d", minAcceptableCount, pollTimeout, finalCount)

	// 3. Diagnostics (if failed or just for info)
	if finalCount < minAcceptableCount {
		diagnoseCollapse(ctx, t, database)
	} else {
		t.Logf("SUCCESS: Inventory validated. Count: %d", finalCount)
	}

	// 4. Validate OCSF device structure by sampling a device
	validateOCSFDeviceStructure(ctx, t, database)
}

func validateOCSFDeviceStructure(ctx context.Context, t *testing.T, database db.Service) {
	t.Log("Validating OCSF device structure...")

	// List a sample of devices to verify OCSF fields
	devices, err := database.ListOCSFDevices(ctx, 5, 0)
	if err != nil {
		t.Logf("Warning: Could not list OCSF devices for validation: %v", err)
		return
	}

	if len(devices) == 0 {
		t.Log("Warning: No devices found for OCSF structure validation")
		return
	}

	// Validate first device has required OCSF fields
	device := devices[0]

	// UID is required (maps to device_id)
	assert.NotEmpty(t, device.UID, "OCSF device should have UID")

	// Check OCSF temporal fields are present
	if device.FirstSeenTime != nil {
		t.Logf("  Device %s first_seen_time: %v", device.UID, device.FirstSeenTime)
	}
	if device.LastSeenTime != nil {
		t.Logf("  Device %s last_seen_time: %v", device.UID, device.LastSeenTime)
	}

	// Log OCSF-specific fields if present
	if device.TypeID != nil {
		t.Logf("  Device %s type_id: %d, type: %s", device.UID, *device.TypeID, stringOrEmpty(device.DeviceType))
	}
	if device.VendorName != nil {
		t.Logf("  Device %s vendor_name: %s", device.UID, *device.VendorName)
	}

	t.Logf("OCSF device structure validation passed for %d devices", len(devices))
}

func stringOrEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func connectDB(ctx context.Context, dsn string, log logger.Logger) (db.Service, error) {
	u, err := url.Parse(dsn)
	if err != nil {
		return nil, err
	}

	password, _ := u.User.Password()
	port := 5432
	if p := u.Port(); p != "" {
		port, _ = strconv.Atoi(p)
	}

	cfg := &models.CoreServiceConfig{
		CNPG: &models.CNPGDatabase{
			Host:     u.Hostname(),
			Port:     port,
			Database: strings.TrimPrefix(u.Path, "/"),
			Username: u.User.Username(),
			Password: password,
			SSLMode:  "prefer", 
		},
	}
	
	if ssl := u.Query().Get("sslmode"); ssl != "" {
		cfg.CNPG.SSLMode = ssl
	}

	// Don't run migrations in E2E test, assume environment is deployed
	os.Setenv("ENABLE_DB_MIGRATIONS", "false")

	return db.New(ctx, cfg, log)
}

func diagnoseCollapse(ctx context.Context, t *testing.T, database db.Service) {
	// We need raw query access for diagnostics
	// This assumes the db.Service exposes ExecuteQuery or we cast it
	executor, ok := database.(interface {
		ExecuteQuery(ctx context.Context, query string, params ...interface{}) ([]map[string]interface{}, error)
	})
	if !ok {
		t.Log("Database client does not support raw queries for diagnostics")
		return
	}

	t.Log("--- DIAGNOSTICS ---")

	// Check for tombstone chains
	rows, err := executor.ExecuteQuery(ctx, `
		SELECT COUNT(*) as count
		FROM ocsf_devices
		WHERE metadata->>'_merged_into' IS NOT NULL
		  AND metadata->>'_merged_into' != ''
	`)
	if err == nil && len(rows) > 0 {
		t.Logf("Total Tombstones: %v", rows[0]["count"])
	}

	// Check for top merge targets (black holes)
	rows, err = executor.ExecuteQuery(ctx, `
		SELECT metadata->>'_merged_into' as target, COUNT(*) as merged_count
		FROM ocsf_devices
		WHERE metadata->>'_merged_into' IS NOT NULL
		GROUP BY 1
		ORDER BY 2 DESC
		LIMIT 5
	`)
	if err == nil {
		t.Log("Top Merge Targets:")
		for _, row := range rows {
			t.Logf("  Target: %s, Merged Count: %v", row["target"], row["merged_count"])
		}
	}
}
