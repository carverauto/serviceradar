package main

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

const (
	starlinkHost    = "starlink.com"
	starlinkAPIBase = "https://" + starlinkHost + "/api/public/v2"

	// maxListPages bounds one listing walk. The vendor fixes list pages at 100
	// rows, so this is 100k rows: far beyond any account, low enough that a
	// server which never reports isLastPage cannot spin a run forever.
	maxListPages = 1000
)

// httpDoer is the SDK HTTP client surface; tests swap in a fake.
type httpDoer interface {
	Do(sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

// apiError carries a stable, non-sensitive code. Response bodies are never
// retained: vendor error text can echo identifiers, and results are
// viewer-readable.
type apiError struct {
	code   string
	status int
}

func (e *apiError) Error() string { return e.code }

func errorCode(err error) string {
	if err == nil {
		return ""
	}
	if typed, ok := err.(*apiError); ok {
		return typed.code
	}
	return "starlink_request_failed"
}

// apiClient calls the Management and Telemetry APIs. It sends no credential:
// the agent host exchanges the brokered service-account credential for a
// bearer token and injects it into every allowed request.
type apiClient struct {
	http      httpDoer
	timeoutMS int
	// budget is the number of requests this run may still make. The vendor
	// limit is per account and shared with every other client of it, so a run
	// stops early rather than spend the whole minute's allowance.
	budget   int
	requests int
}

func newAPIClient(doer httpDoer, cfg Config) *apiClient {
	return &apiClient{http: doer, timeoutMS: cfg.TimeoutMS, budget: cfg.MaxRequestsPerRun}
}

// call performs one request and returns the envelope's content.
func (c *apiClient) call(method, path string, query url.Values, body []byte, timeoutMS int) (gjson.Result, error) {
	if c.budget <= 0 {
		return gjson.Result{}, &apiError{code: "starlink_request_budget_exhausted"}
	}
	c.budget--
	c.requests++

	target := starlinkAPIBase + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	if timeoutMS <= 0 {
		timeoutMS = c.timeoutMS
	}

	req := sdk.HTTPRequest{
		Method:    method,
		URL:       target,
		Headers:   map[string]string{"Accept": "application/json"},
		TimeoutMS: timeoutMS,
	}
	if body != nil {
		req.Headers["Content-Type"] = "application/json"
		req.Body = body
	}

	resp, err := c.http.Do(req)
	if err != nil || resp == nil {
		return gjson.Result{}, &apiError{code: "starlink_request_failed"}
	}
	if code := statusErrorCode(resp.Status); code != "" {
		return gjson.Result{}, &apiError{code: code, status: resp.Status}
	}

	envelope := gjson.ParseBytes(resp.Body)
	if !envelope.IsObject() {
		return gjson.Result{}, &apiError{code: "starlink_response_invalid", status: resp.Status}
	}
	// Telemetry stream responses are not wrapped in the ServiceResponse
	// envelope; they carry data/metadata at the top level.
	if !envelope.Get("isValid").Exists() {
		return envelope, nil
	}
	if !envelope.Get("isValid").Bool() {
		return gjson.Result{}, &apiError{code: "starlink_request_rejected", status: resp.Status}
	}
	return envelope.Get("content"), nil
}

func statusErrorCode(status int) string {
	switch {
	case status >= 200 && status < 300:
		return ""
	case status == http.StatusUnauthorized:
		return "starlink_auth_failed"
	case status == http.StatusForbidden:
		return "starlink_permission_denied"
	case status == http.StatusNotFound:
		return "starlink_not_found"
	case status == http.StatusUnprocessableEntity:
		return "starlink_validation_failed"
	case status == http.StatusTooManyRequests:
		return "starlink_rate_limited"
	case status >= 500:
		return "starlink_upstream_error"
	default:
		return "starlink_http_" + strconv.Itoa(status)
	}
}

// listPages walks an index-paginated listing, calling visit for every row.
// It returns the number of pages read; a failure mid-walk returns the error
// with the rows visited so far already delivered.
func (c *apiClient) listPages(path string, query url.Values, visit func(gjson.Result)) (int, error) {
	return c.walkPages(path, query, func(rows []gjson.Result) {
		for _, row := range rows {
			visit(row)
		}
	})
}

// listPagesBatched is listPages delivering one page of rows at a time.
func (c *apiClient) listPagesBatched(path string, visit func([]gjson.Result)) (int, error) {
	return c.walkPages(path, nil, visit)
}

func (c *apiClient) walkPages(path string, query url.Values, visit func([]gjson.Result)) (int, error) {
	pages := 0
	for page := 0; page < maxListPages; page++ {
		q := url.Values{}
		for key, values := range query {
			q[key] = values
		}
		q.Set("page", strconv.Itoa(page))

		content, err := c.call(http.MethodGet, path, q, nil, 0)
		if err != nil {
			return pages, err
		}
		pages++

		rows := content.Get("results").Array()
		visit(rows)
		if content.Get("isLastPage").Bool() || len(rows) == 0 {
			return pages, nil
		}
	}
	return pages, &apiError{code: "starlink_pagination_unbounded"}
}

func trimmed(result gjson.Result, path string) string {
	return strings.TrimSpace(result.Get(path).String())
}
