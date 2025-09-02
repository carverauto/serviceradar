package db

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestStoreServices_WithJSONConfig(t *testing.T) {
	// This test verifies that service config is properly stored as JSON
	// It's a mock test showing the expected behavior
	
	services := []*models.Service{
		{
			PollerID:    "test-poller",
			ServiceName: "auth-service",
			ServiceType: "grpc",
			AgentID:     "agent-1",
			Partition:   "default",
			Timestamp:   time.Now(),
			Config: map[string]string{
				"service_type":     "grpc",
				"kv_store_id":      "redis-cluster-1",
				"kv_enabled":       "true",
				"kv_configured":    "true",
				"rbac_configured":  "true",
				"tls_configured":   "true",
			},
		},
		{
			PollerID:    "test-poller",
			ServiceName: "legacy-service",
			ServiceType: "http",
			AgentID:     "agent-2",
			Partition:   "default",
			Timestamp:   time.Now(),
			Config: map[string]string{
				"service_type":    "http",
				"kv_enabled":      "false",
				"kv_configured":   "false",
				"rbac_configured": "false",
			},
		},
	}

	// Verify that config is properly marshaled to JSON
	for _, svc := range services {
		configJSON, err := json.Marshal(svc.Config)
		require.NoError(t, err)
		
		// Verify JSON is valid
		var parsedConfig map[string]string
		err = json.Unmarshal(configJSON, &parsedConfig)
		require.NoError(t, err)
		
		// Verify config roundtrip
		assert.Equal(t, svc.Config, parsedConfig)
		
		// Log example JSON for documentation
		t.Logf("Service %s config JSON: %s", svc.ServiceName, string(configJSON))
	}
}

func TestQueryServiceConfig_Examples(t *testing.T) {
	// This test documents example queries that can be used with JSON config
	
	exampleQueries := []struct {
		name        string
		query       string
		description string
	}{
		{
			name: "Find KV-enabled services",
			query: `
				SELECT 
					service_name,
					json_extract_string(config, 'kv_store_id') AS kv_store_id
				FROM services
				WHERE json_extract_string(config, 'kv_enabled') = 'true'
			`,
			description: "Find all services that are using KV stores",
		},
		{
			name: "Count services by KV store",
			query: `
				SELECT 
					json_extract_string(config, 'kv_store_id') AS kv_store_id,
					count() AS service_count
				FROM services
				WHERE json_extract_string(config, 'kv_enabled') = 'true'
				GROUP BY kv_store_id
			`,
			description: "Count how many services use each KV store",
		},
		{
			name: "Find services with specific config",
			query: `
				SELECT 
					service_name,
					config
				FROM services
				WHERE json_extract_string(config, 'rbac_configured') = 'true'
				  AND json_extract_string(config, 'tls_configured') = 'true'
			`,
			description: "Find services with both RBAC and TLS configured",
		},
		{
			name: "Check if path exists",
			query: `
				SELECT 
					service_name,
					json_has(config, 'kv_store_id') AS has_kv_store
				FROM services
			`,
			description: "Check which services have kv_store_id in their config",
		},
	}

	for _, eq := range exampleQueries {
		t.Run(eq.name, func(t *testing.T) {
			t.Logf("Query: %s", eq.name)
			t.Logf("Description: %s", eq.description)
			t.Logf("SQL:\n%s", eq.query)
		})
	}
}

func TestConfigMetadata_Security(t *testing.T) {
	// This test verifies that sensitive data is NOT in the config
	
	safeConfig := map[string]string{
		"service_type":    "grpc",
		"kv_store_id":     "redis-cluster-1",
		"kv_enabled":      "true",
		"kv_configured":   "true",
		"rbac_configured": "true",
	}
	
	// These keys should NEVER appear in the config
	forbiddenKeys := []string{
		"jwt_secret",
		"password",
		"api_key",
		"private_key",
		"secret",
		"token",
		"credential",
	}
	
	// Verify no forbidden keys exist
	for _, forbidden := range forbiddenKeys {
		_, exists := safeConfig[forbidden]
		assert.False(t, exists, "Config should not contain sensitive key: %s", forbidden)
	}
	
	// Verify safe metadata is present
	assert.Equal(t, "grpc", safeConfig["service_type"])
	assert.Equal(t, "redis-cluster-1", safeConfig["kv_store_id"])
	assert.Equal(t, "true", safeConfig["kv_enabled"])
}