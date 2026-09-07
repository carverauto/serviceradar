package main

import (
	"context"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

type testProtectHTTPClient struct {
	BaseURL    string
	Timeout    time.Duration
	AuthHeader string
	HTTPClient *http.Client
}

func (c *testProtectHTTPClient) URL(path string) string {
	return c.BaseURL + path
}

func (c *testProtectHTTPClient) DoContext(ctx context.Context, req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	client := c.HTTPClient
	if client == nil {
		client = http.DefaultClient
	}

	body := io.Reader(nil)
	if len(req.Body) > 0 {
		body = strings.NewReader(string(req.Body))
	}

	httpReq, err := http.NewRequestWithContext(ctx, req.Method, req.URL, body)
	if err != nil {
		return nil, err
	}
	for key, value := range req.Headers {
		httpReq.Header.Set(key, value)
	}
	if c.AuthHeader != "" && httpReq.Header.Get("Authorization") == "" {
		httpReq.Header.Set("Authorization", c.AuthHeader)
	}

	start := time.Now()
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	headers := make(map[string]string, len(resp.Header))
	for key, values := range resp.Header {
		headers[key] = strings.Join(values, ", ")
	}

	return &sdk.HTTPResponse{
		Status:   resp.StatusCode,
		Headers:  headers,
		Body:     respBody,
		Duration: time.Since(start),
	}, nil
}
