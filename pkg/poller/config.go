// Package poller pkg/poller/config.go provides a function to load the configuration from a file.
package poller

import (
	"encoding/json"
	"os"
)

func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}

	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return Config{}, err
	}

	return config, nil
}
