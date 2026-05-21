//go:build tinygo

package main

func applyRuntimeConfigLimits(cfg *Config) {
	if cfg == nil {
		return
	}
	includeGuests := false
	cfg.IncludeGuests = &includeGuests
}
