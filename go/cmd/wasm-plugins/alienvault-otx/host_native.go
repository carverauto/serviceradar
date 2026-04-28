//go:build !tinygo

package main

import (
	"context"
	"net/http"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func doOTXHostHTTPRequest(apiURL, apiKey string, timeoutMS int) (*sdk.HTTPResponse, error) {
	return sdk.HTTP.DoContext(context.Background(), sdk.HTTPRequest{
		Method: http.MethodGet,
		URL:    apiURL,
		Headers: map[string]string{
			"accept":        "application/json",
			"X-OTX-API-KEY": apiKey,
		},
		TimeoutMS: timeoutMS,
	})
}
