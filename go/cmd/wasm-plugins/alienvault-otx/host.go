package main

import (
	"net/http"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

// otxHTTP is package-level so tests can swap it for a fake.
var otxHTTP httpClient = &sdk.HTTPClient{MaxResponseBytes: sdk.MaxHTTPResponseBytes}

type httpClient interface {
	Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

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
