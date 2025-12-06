//go:build integration

package registry

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
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

// TestIntegration_IPChurn_DifferentStrongIdentities runs against a real CNPG database.
// WARNING: This test drops `device_updates` and `unified_devices` tables to ensure a clean schema.
// It should only be run against a disposable fixture database.
func TestIntegration_IPChurn_DifferentStrongIdentities(t *testing.T) {
	connStr := os.Getenv("SRQL_TEST_DATABASE_URL")
	if connStr == "" {
		t.Skip("SRQL_TEST_DATABASE_URL not set")
	}

	// Parse connection string to populate config
	u, err := url.Parse(connStr)
	require.NoError(t, err)

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
	
	// Check for query params override
	if ssl := u.Query().Get("sslmode"); ssl != "" {
		cfg.CNPG.SSLMode = ssl
	}
	
	// Skip migrations to avoid conflict with existing data/schema state
	os.Setenv("ENABLE_DB_MIGRATIONS", "false")

	log := logger.NewTestLogger()
	ctx := context.Background()

	// Initialize DB service
	database, err := db.New(ctx, cfg, log)
	require.NoError(t, err)
	defer database.Close()
	
	// Drop tables to ensure clean schema (destructive, but needed for test consistency on fixture DB)
	_, err = database.ExecuteQuery(ctx, "DROP TABLE IF EXISTS device_updates")
	require.NoError(t, err)
	_, err = database.ExecuteQuery(ctx, "DROP TABLE IF EXISTS unified_devices")
	require.NoError(t, err)

	// Ensure device_updates table exists (minimal schema for test matching Go code)
	_, err = database.ExecuteQuery(ctx, `
		CREATE TABLE device_updates (
			device_id TEXT NOT NULL,
			ip TEXT,
			discovery_source TEXT,
			agent_id TEXT,
			poller_id TEXT,
			partition TEXT,
			observed_at TIMESTAMPTZ NOT NULL,
			hostname TEXT,
			mac TEXT,
			metadata JSONB,
			available BOOLEAN
		);
	`)
	require.NoError(t, err)
	
	// Ensure unified_devices exists too
	_, err = database.ExecuteQuery(ctx, `
		CREATE TABLE unified_devices (
			device_id TEXT PRIMARY KEY,
			ip TEXT,
			poller_id TEXT,
			agent_id TEXT,
			hostname TEXT,
			mac TEXT,
			discovery_sources TEXT[],
			first_seen TIMESTAMPTZ,
			last_seen TIMESTAMPTZ,
			is_available BOOLEAN,
			device_type TEXT DEFAULT 'network_device',
			service_type TEXT,
			service_status TEXT,
			last_heartbeat TIMESTAMPTZ,
			os_info TEXT,
			version_info TEXT,
			metadata JSONB,
			updated_at TIMESTAMPTZ DEFAULT now()
		);
	`)
	require.NoError(t, err)

	// Initialize Registry
	// We need to ensure we use the DB for both storage and resolution
	// The registry defaults to using the passed DB for resolution if no other resolver provided.
	reg := NewDeviceRegistry(database, log)

	// Generate unique test data to avoid conflicts
	runID := randomString(6)
	ip := fmt.Sprintf("10.255.%d.%d", randomInt(255), randomInt(255))
	
	deviceA := "sr:test-A-" + runID
	armisA := "armis-A-" + runID
	
	deviceB := "sr:test-B-" + runID
	armisB := "armis-B-" + runID

	t.Logf("Test Run %s: Using IP %s", runID, ip)

	// Step 1: Ingest Device A
	updateA := &models.DeviceUpdate{
		DeviceID:    deviceA,
		IP:          ip,
		Source:      models.DiscoverySourceArmis,
		Timestamp:   time.Now(),
		IsAvailable: true,
		Metadata: map[string]string{
			"armis_device_id": armisA,
			"test_run":        runID,
		},
	}

	err = reg.ProcessDeviceUpdate(ctx, updateA)
	require.NoError(t, err)

	// Verify Device A is active and has the IP
	devA, err := database.GetUnifiedDevice(ctx, deviceA)
	require.NoError(t, err)
	assert.Equal(t, ip, devA.IP)
	assert.Equal(t, armisA, devA.Metadata.Value["armis_device_id"])

	// Step 2: Ingest Device B with SAME IP but DIFFERENT Armis ID
	// This simulates IP churn where Device A lost the IP and Device B got it.
	updateB := &models.DeviceUpdate{
		DeviceID:    deviceB,
		IP:          ip,
		Source:      models.DiscoverySourceArmis,
		Timestamp:   time.Now().Add(time.Second), // Newer
		IsAvailable: true,
		Metadata: map[string]string{
			"armis_device_id": armisB,
			"test_run":        runID,
		},
	}

	err = reg.ProcessDeviceUpdate(ctx, updateB)
	require.NoError(t, err)

	// Step 3: Verification
	
	// Device B should exist and have the IP
	devB, err := database.GetUnifiedDevice(ctx, deviceB)
	require.NoError(t, err)
	assert.Equal(t, ip, devB.IP)
	assert.Equal(t, armisB, devB.Metadata.Value["armis_device_id"])
	
	// Device B should NOT be a tombstone (merged into A)
	if devB.Metadata != nil {
		assert.Empty(t, devB.Metadata.Value["_merged_into"], "Device B should not be merged into Device A")
	}

	// Device A should still exist but have its IP cleared
	devA_After, err := database.GetUnifiedDevice(ctx, deviceA)
	require.NoError(t, err)
	
	// In the implementation, we set IP to "0.0.0.0" to clear it
	assert.Equal(t, "0.0.0.0", devA_After.IP, "Device A should have its IP cleared")
	assert.Equal(t, "true", devA_After.Metadata.Value["_ip_cleared_due_to_churn"])
}

func randomString(n int) string {
	bytes := make([]byte, n/2)
	rand.Read(bytes)
	return hex.EncodeToString(bytes)
}

func randomInt(max int) int {
	b := make([]byte, 1)
	rand.Read(b)
	return int(b[0]) % max
}
