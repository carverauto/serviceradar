//go:build !tinygo

package main

import "encoding/json"

func configFromRawConfig(raw string) Config {
	cfg, err := configFromJSON(json.RawMessage(raw))
	if err != nil {
		return defaultConfig()
	}

	return cfg
}
