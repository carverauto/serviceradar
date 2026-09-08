package main

import (
	"context"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func runPlugin() error {
	cfg, err := loadRuntimeConfig()
	if err != nil {
		return submitPluginError(err)
	}

	snapshot, err := NewCollector(SDKHTTPDoer{}).Collect(context.Background(), cfg)
	if err != nil {
		return submitPluginError(err)
	}

	result, err := buildPluginResult(snapshot, cfg.MaxResultBytes)
	if err != nil {
		return submitPluginError(err)
	}
	return sdk.Execute(func() (*sdk.Result, error) { return result, nil })
}

func submitPluginError(err error) error {
	code := safeErrorCode(err)
	return sdk.Execute(func() (*sdk.Result, error) {
		return sdk.Critical(code), nil
	})
}
