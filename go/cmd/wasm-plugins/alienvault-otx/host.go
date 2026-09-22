package main

import (
	"net/http"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// otxHTTP is package-level so tests can swap it for a fake.
var otxHTTP httpClient = &sdk.HTTPClient{MaxResponseBytes: sdk.MaxHTTPResponseBytes}

type httpClient interface {
	Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

func doOTXHostHTTPRequest(apiURL, apiKey string, timeoutMS int) (*sdk.HTTPResponse, error) {
	requestTimeoutMS, err := reserveOTXPullAttempt(timeoutMS)
	if err != nil {
		return nil, err
	}

	return otxHTTP.Do(sdk.HTTPRequest{
		Method: http.MethodGet,
		URL:    apiURL,
		Headers: map[string]string{
			"accept":        "application/json",
			"X-OTX-API-KEY": apiKey,
		},
		TimeoutMS: requestTimeoutMS,
	})
}

func reserveOTXPullAttempt(timeoutMS int) (int, error) {
	if otxPullAttemptLimit > 0 && otxAttempts >= otxPullAttemptLimit {
		return 0, errOTXPullBudget
	}

	if !otxPullDeadline.IsZero() {
		remaining := otxPullDeadline.Sub(otxNow())
		if remaining <= 0 {
			return 0, errOTXPullBudget
		}

		remainingMS := int(remaining.Milliseconds())
		if remainingMS < 1 {
			remainingMS = 1
		}
		if timeoutMS <= 0 || timeoutMS > remainingMS {
			timeoutMS = remainingMS
		}
	}

	if timeoutMS < 1 {
		timeoutMS = 1
	}

	// Count every actual upstream attempt, including adaptive coordinate changes
	// and retries, so a rejected daily pull reports how hard it tried.
	otxAttempts++
	return timeoutMS, nil
}
