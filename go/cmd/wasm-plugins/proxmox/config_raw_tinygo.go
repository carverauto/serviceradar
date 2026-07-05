//go:build tinygo

package main

// configFromRawConfig under TinyGo delegates to the shared gjson-based parser
// in config_raw_parse.go. TinyGo builds avoid encoding/json here (limited
// reflect support), but the parsing semantics must match the std build's
// configFromJSON path — enforced by TestConfigFromRawConfigGJSONMatchesStdParser.
func configFromRawConfig(raw string) Config {
	return configFromRawConfigGJSON(raw)
}
