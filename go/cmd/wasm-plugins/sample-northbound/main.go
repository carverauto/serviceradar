//go:build tinygo

package main

import "code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"

//export run_check
func run_check() {
	hostConfig, err := sdk.LoadActionConfig()
	if err != nil {
		_ = sdk.SubmitActionResult(sdk.ActionFailed("config_error", err.Error()))
		return
	}

	_ = sdk.SubmitActionResult(handleAction(hostConfig, decodePluginConfig(hostConfig)))
}

func main() {}
