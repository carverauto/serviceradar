package config

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
)

// FileConfigLoader loads configuration from a local JSON file.
type FileConfigLoader struct{}

// Load implements ConfigLoader by reading and unmarshaling a JSON file.
func (f *FileConfigLoader) Load(_ context.Context, path string, dst interface{}) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("failed to read file '%s': %w", path, err)
	}

	if err := json.Unmarshal(data, dst); err != nil {
		return fmt.Errorf("failed to unmarshal JSON from '%s': %w", path, err)
	}

	return nil
}
