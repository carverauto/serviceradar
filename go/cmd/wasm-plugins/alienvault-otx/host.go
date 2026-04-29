package main

import (
	"net/http"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func doOTXHostHTTPRequest(apiURL, apiKey string, timeoutMS int) (*sdk.HTTPResponse, error) {
	return sdk.HTTP.Do(sdk.HTTPRequest{
		Method: http.MethodGet,
		URL:    apiURL,
		Headers: map[string]string{
			"accept":        "application/json",
			"X-OTX-API-KEY": apiKey,
		},
		TimeoutMS: timeoutMS,
	})
}
