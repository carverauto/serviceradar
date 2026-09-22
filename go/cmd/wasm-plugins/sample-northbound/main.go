//go:build tinygo

package main

import (
	"encoding/json"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

//export run_check
func run_check() {
	var raw map[string]any
	if err := sdk.LoadConfig(&raw); err != nil {
		_ = sdk.Execute(func() (*sdk.Result, error) {
			return sdk.Unknown("sample northbound NMS configuration could not be loaded"), nil
		})
		return
	}

	if _, ok := raw["action_invocation"]; !ok {
		cfg := decodePluginConfigMap(raw)
		_ = sdk.Execute(func() (*sdk.Result, error) {
			return serviceCheckResult(cfg), nil
		})
		return
	}

	payload, err := json.Marshal(normalizeActionInvocationConfig(raw))
	if err != nil {
		_ = sdk.SubmitActionResult(sdk.ActionFailed("config_error", err.Error()))
		return
	}

	hostConfig, err := sdk.ParseActionConfig(payload)
	if err != nil {
		_ = sdk.SubmitActionResult(sdk.ActionFailed("config_error", err.Error()))
		return
	}
	_ = sdk.SubmitActionResult(handleAction(hostConfig, decodePluginConfig(hostConfig)))
}

func main() {}
