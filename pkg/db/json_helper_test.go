package db

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestJSONMap_Value(t *testing.T) {
	// Test empty JSONMap
	emptyMap := JSONMap{}
	val, err := emptyMap.Value()
	require.NoError(t, err)
	assert.Equal(t, "{}", val)

	// Test nil JSONMap
	var nilMap JSONMap
	val, err = nilMap.Value()
	require.NoError(t, err)
	assert.Equal(t, "{}", val)

	// Test JSONMap with data
	testMap := JSONMap{
		"service_type":    "grpc",
		"kv_store_id":     "redis-cluster-1",
		"kv_enabled":      "true",
		"kv_configured":   "true",
		"rbac_configured": "true",
	}
	
	val, err = testMap.Value()
	require.NoError(t, err)
	
	// The Value should be a valid JSON string
	valStr, ok := val.(string)
	require.True(t, ok, "Value should return a string")
	
	// Verify it's valid JSON
	var parsed map[string]string
	err = json.Unmarshal([]byte(valStr), &parsed)
	require.NoError(t, err, "Value should be valid JSON")
	
	// Verify content matches
	assert.Equal(t, "grpc", parsed["service_type"])
	assert.Equal(t, "redis-cluster-1", parsed["kv_store_id"])
	assert.Equal(t, "true", parsed["kv_enabled"])
}

func TestJSONMap_String(t *testing.T) {
	testMap := JSONMap{
		"kv_configured": "false",
		"kv_enabled":    "false",
		"service_type":  "grpc",
	}
	
	jsonStr := testMap.String()
	t.Logf("JSON output: %s", jsonStr)
	
	// Verify it produces valid JSON
	var parsed map[string]string
	err := json.Unmarshal([]byte(jsonStr), &parsed)
	require.NoError(t, err)
	
	assert.Equal(t, "false", parsed["kv_configured"])
	assert.Equal(t, "false", parsed["kv_enabled"])
	assert.Equal(t, "grpc", parsed["service_type"])
}

func TestFromMap_Integration(t *testing.T) {
	// Test the exact data from the error message
	originalMap := map[string]string{
		"kv_configured": "false",
		"kv_enabled":    "false",
		"service_type":  "grpc",
	}
	
	jsonMap := FromMap(originalMap)
	val, err := jsonMap.Value()
	require.NoError(t, err)
	
	t.Logf("Database value: %v", val)
	
	// This should be the exact JSON string that gets sent to ClickHouse
	expectedJSON := `{"kv_configured":"false","kv_enabled":"false","service_type":"grpc"}`
	valStr := val.(string)
	
	// Parse both to compare (since JSON key order might vary)
	var expected, actual map[string]string
	require.NoError(t, json.Unmarshal([]byte(expectedJSON), &expected))
	require.NoError(t, json.Unmarshal([]byte(valStr), &actual))
	
	assert.Equal(t, expected, actual)
}