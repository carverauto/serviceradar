package main

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

type HTTPRequest struct {
	Method             string
	URL                string
	Headers            map[string]string
	Body               []byte
	TimeoutMS          int
	InsecureSkipVerify bool
}

type HTTPResponse struct {
	Status  int
	Headers map[string]string
	Body    []byte
}

type HTTPDoer interface {
	Do(context.Context, HTTPRequest) (HTTPResponse, error)
}

type SDKHTTPDoer struct{}

func (SDKHTTPDoer) Do(ctx context.Context, request HTTPRequest) (HTTPResponse, error) {
	response, err := sdk.HTTP.DoContext(ctx, sdk.HTTPRequest{
		Method:             request.Method,
		URL:                request.URL,
		Headers:            request.Headers,
		Body:               request.Body,
		ResponseMode:       "envelope",
		TimeoutMS:          request.TimeoutMS,
		InsecureSkipVerify: request.InsecureSkipVerify,
	})
	if err != nil {
		return HTTPResponse{}, err
	}
	return HTTPResponse{
		Status:  response.Status,
		Headers: response.Headers,
		Body:    response.Body,
	}, nil
}

type sleepFunc func(context.Context, time.Duration) error

func sleepWithContext(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
