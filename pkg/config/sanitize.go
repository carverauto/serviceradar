package config

import (
	"encoding/json"

	"github.com/carverauto/serviceradar/pkg/models"
)

// sanitizeForKV marshals a configuration struct after removing any fields marked
// with `sensitive:"true"` tags. Callers should only persist the sanitized bytes
// to shared stores such as the datasvc KV bucket.
func sanitizeForKV(cfg interface{}) ([]byte, error) {
	if cfg == nil {
		return nil, nil
	}

	safeData, err := models.FilterSensitiveFields(cfg)
	if err != nil {
		return nil, err
	}

	if len(safeData) == 0 {
		return json.Marshal(cfg)
	}

	return json.Marshal(safeData)
}
