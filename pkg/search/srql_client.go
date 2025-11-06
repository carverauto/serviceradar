package search

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

const (
	defaultSRQLPath    = "/api/query"
	defaultHTTPTimeout = 15 * time.Second
)

// SRQLRequest represents an outbound query to the SRQL microservice.
type SRQLRequest struct {
	Query     string `json:"query"`
	Limit     int    `json:"limit,omitempty"`
	Cursor    string `json:"cursor,omitempty"`
	Direction string `json:"direction,omitempty"`
}

// SRQLResult captures the response payload returned by the SRQL microservice.
type SRQLResult struct {
	Rows              []map[string]interface{}
	Pagination        Pagination
	UnsupportedTokens []string
}

// HTTPClientConfig controls how the SRQL HTTP client behaves.
type HTTPClientConfig struct {
	BaseURL string
	APIKey  string
	Timeout time.Duration
	Path    string
	Logger  logger.Logger
	HTTP    *http.Client
}

type httpSRQLClient struct {
	baseURL *url.URL
	apiKey  string
	path    string
	client  *http.Client
	logger  logger.Logger
}

// NewHTTPClient constructs an SRQL client backed by HTTP.
func NewHTTPClient(cfg HTTPClientConfig) (SRQLClient, error) {
	if strings.TrimSpace(cfg.BaseURL) == "" {
		return nil, errors.New("srql base url is required")
	}

	parsed, err := url.Parse(cfg.BaseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid srql base url: %w", err)
	}

	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = defaultHTTPTimeout
	}

	httpClient := cfg.HTTP
	if httpClient == nil {
		httpClient = &http.Client{Timeout: timeout}
	}

	p := cfg.Path
	if strings.TrimSpace(p) == "" {
		p = defaultSRQLPath
	}

	return &httpSRQLClient{
		baseURL: parsed,
		apiKey:  cfg.APIKey,
		path:    p,
		client:  httpClient,
		logger:  cfg.Logger,
	}, nil
}

// Query executes the supplied SRQL request and normalizes the response.
func (c *httpSRQLClient) Query(ctx context.Context, req SRQLRequest) (*SRQLResult, error) {
	if strings.TrimSpace(req.Query) == "" {
		return nil, errors.New("srql query cannot be empty")
	}

	body := map[string]interface{}{
		"query": req.Query,
	}
	if req.Limit > 0 {
		body["limit"] = req.Limit
	}
	if req.Cursor != "" {
		body["cursor"] = req.Cursor
	}
	if req.Direction != "" {
		body["direction"] = req.Direction
	}

	payload, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal srql request: %w", err)
	}

	endpoint := *c.baseURL
	endpoint.Path = path.Join(endpoint.Path, c.path)

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("failed to create srql http request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	if c.apiKey != "" {
		httpReq.Header.Set("X-API-Key", c.apiKey)
	}

	resp, err := c.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("srql request failed: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("srql response status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	var decoded struct {
		Results    []map[string]interface{} `json:"results"`
		Pagination struct {
			NextCursor string `json:"next_cursor"`
			PrevCursor string `json:"prev_cursor"`
			Limit      int    `json:"limit"`
		} `json:"pagination"`
		Unsupported []string `json:"unsupported_tokens"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&decoded); err != nil {
		return nil, fmt.Errorf("failed to decode srql response: %w", err)
	}

	if c.logger != nil {
		c.logger.Debug().
			Str("engine", "srql").
			Int("row_count", len(decoded.Results)).
			Msg("SRQL query executed")
	}

	return &SRQLResult{
		Rows: decoded.Results,
		Pagination: Pagination{
			NextCursor: decoded.Pagination.NextCursor,
			PrevCursor: decoded.Pagination.PrevCursor,
			Limit:      decoded.Pagination.Limit,
		},
		UnsupportedTokens: decoded.Unsupported,
	}, nil
}
