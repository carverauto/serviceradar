// Package main implements the Proxmox inventory WASM plugin for ServiceRadar.
package main

import "github.com/carverauto/serviceradar-sdk-go/v2/sdk"

//export run_check
func run_check() {
	cfg, err := loadConfig()
	if err != nil {
		_ = submitPluginResult(newPluginResult(sdk.StatusUnknown, "Proxmox configuration could not be loaded"))
		return
	}
	applyRuntimeConfigLimits(&cfg)

	result, err := runProxmoxCheck(cfg)
	if err != nil {
		_ = submitPluginResult(newPluginResult(sdk.StatusCritical, sanitizeError(err)))
		return
	}

	_ = submitPluginResult(result)
}

func main() {}
