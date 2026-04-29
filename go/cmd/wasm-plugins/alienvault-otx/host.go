package main

import (
	"net/http"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

var otxHTTP = &sdk.HTTPClient{MaxResponseBytes: 512 * 1024}

func doOTXHostHTTPRequest(apiURL, apiKey string, timeoutMS int) (*sdk.HTTPResponse, error) {
	return otxHTTP.Do(sdk.HTTPRequest{
		Method: http.MethodGet,
		URL:    apiURL,
		Headers: map[string]string{
			"accept":        "application/json",
			"X-OTX-API-KEY": apiKey,
		},
		TimeoutMS: timeoutMS,
	})
}
