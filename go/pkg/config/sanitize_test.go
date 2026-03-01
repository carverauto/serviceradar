package config

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

type sampleConfig struct {
	Public string       `json:"public"`
	Secret string       `json:"secret" sensitive:"true"`
	Nested sampleNested `json:"nested"`
}

type sampleNested struct {
	Value  string `json:"value"`
	Secret string `json:"secret" sensitive:"true"`
}

func TestSanitizeForKV_RemovesSensitiveFields(t *testing.T) {
	cfg := sampleConfig{
		Public: "visible",
		Secret: "top-secret",
		Nested: sampleNested{
			Value:  "nested",
			Secret: "nested-secret",
		},
	}

	data, err := sanitizeForKV(cfg)
	require.NoError(t, err)

	var result map[string]interface{}
	require.NoError(t, json.Unmarshal(data, &result))

	require.Equal(t, "visible", result["public"])
	require.NotContains(t, result, "secret")

	nested := result["nested"].(map[string]interface{})
	require.Equal(t, "nested", nested["value"])
	require.NotContains(t, nested, "secret")
}
