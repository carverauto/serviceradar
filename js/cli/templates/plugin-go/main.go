//go:build tinygo

package main

import (
	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// Config is decoded from the per-assignment configuration an operator sets in
// ServiceRadar. Add fields here and declare them in config.schema.json to have
// the UI render inputs for them.
type Config struct {
	Message string `json:"message"`
}

// run_check is the manifest's `entrypoint`. The name must match plugin.yaml.
//
//export run_check
func run_check() {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		cfg := Config{Message: "hello from __PLUGIN_NAME__"}
		_ = sdk.LoadConfig(&cfg)

		sdk.Log.Info("running __PLUGIN_ID__")

		return sdk.Ok(cfg.Message), nil
	})
}

func main() {}
