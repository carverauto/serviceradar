package sdk

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

var errCameraHostRequired = errors.New("host is required")

// CameraHTTPClient wraps the shared HTTP request behavior for camera plugins.
type CameraHTTPClient struct {
	BaseURL            string
	Timeout            time.Duration
	AuthHeader         string
	InsecureSkipVerify bool
}

// NewCameraHTTPClient builds a shared HTTP client from camera plugin config.
func NewCameraHTTPClient(cfg CameraPluginConfig, fallbackTimeout time.Duration) (*CameraHTTPClient, error) {
	host := strings.TrimSpace(cfg.Host)
	if host == "" {
		return nil, errCameraHostRequired
	}

	scheme, err := cfg.NormalizedScheme()
	if err != nil {
		return nil, err
	}

	return &CameraHTTPClient{
		BaseURL:            fmt.Sprintf("%s://%s", scheme, host),
		Timeout:            cfg.ParsedTimeout(fallbackTimeout),
		AuthHeader:         cfg.BasicAuthHeader(),
		InsecureSkipVerify: cfg.InsecureSkipVerify,
	}, nil
}

// URL resolves a relative path against the camera base URL.
func (c *CameraHTTPClient) URL(path string) string {
	if c == nil {
		return path
	}

	return c.BaseURL + path
}

// DoContext performs an HTTP request with the shared auth and timeout settings.
func (c *CameraHTTPClient) DoContext(ctx context.Context, req HTTPRequest) (*HTTPResponse, error) {
	if c == nil {
		return nil, errCameraHostRequired
	}

	if req.URL == "" {
		req.URL = c.BaseURL
	}
	if req.TimeoutMS == 0 {
		req.TimeoutMS = int(c.Timeout.Milliseconds())
	}
	if c.InsecureSkipVerify {
		req.InsecureSkipVerify = true
	}
	if c.AuthHeader != "" {
		if req.Headers == nil {
			req.Headers = map[string]string{}
		}
		if _, ok := req.Headers["Authorization"]; !ok {
			req.Headers["Authorization"] = c.AuthHeader
		}
	}

	return HTTP.DoContext(ctx, req)
}

// GetContext performs a GET request against a relative path.
func (c *CameraHTTPClient) GetContext(ctx context.Context, path string) (*HTTPResponse, error) {
	return c.DoContext(ctx, HTTPRequest{
		Method: "GET",
		URL:    c.URL(path),
	})
}
