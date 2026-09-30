package main

import (
	"encoding/json"
	"net/url"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// Every identifier in these fixtures is invented. Terminal IDs are obviously
// synthetic hex groups, serials use a TEST infix, and the account and service
// line numbers are zero-padded placeholders in the vendor's format.
const (
	testAccountNumber = "ACC-000000-00000-01"
	testTerminalA     = "a1a1a1a1-00000001-00000001"
	testTerminalB     = "b2b2b2b2-00000002-00000002"
	testRouterA       = "Router-0000000000000000000000a1"
	testServiceLine   = "SL-TST-000000-00000-01"
)

type fakeResponse struct {
	status int
	body   string
}

// fakeHTTP serves canned responses keyed by "METHOD path?page=N" (the query is
// matched exactly, so page walks are explicit in each test).
type fakeHTTP struct {
	t         *testing.T
	responses map[string]fakeResponse
	requests  []sdk.HTTPRequest
}

func newFakeHTTP(t *testing.T) *fakeHTTP {
	return &fakeHTTP{t: t, responses: map[string]fakeResponse{}}
}

func (f *fakeHTTP) on(method, pathAndQuery string, status int, body string) {
	f.responses[method+" "+pathAndQuery] = fakeResponse{status: status, body: body}
}

func (f *fakeHTTP) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	f.requests = append(f.requests, req)
	u, err := url.Parse(req.URL)
	if err != nil {
		f.t.Fatalf("bad request URL %q: %v", req.URL, err)
	}
	if u.Host != starlinkHost {
		f.t.Fatalf("request left the vendor host: %q", req.URL)
	}
	if _, ok := req.Headers["Authorization"]; ok {
		f.t.Fatalf("guest set an Authorization header; credentials must be host-injected")
	}
	key := req.Method + " " + strings.TrimPrefix(u.Path, "/api/public/v2")
	if u.RawQuery != "" {
		key += "?" + u.RawQuery
	}
	resp, ok := f.responses[key]
	if !ok {
		f.t.Fatalf("unexpected request %s", key)
	}
	return &sdk.HTTPResponse{Status: resp.status, Body: []byte(resp.body)}, nil
}

func envelope(content string) string {
	return `{"errors":[],"warnings":[],"information":[],"isValid":true,"content":` + content + `}`
}

// sequencedHTTP answers successive requests with successive bodies (status
// 200), for endpoints such as the telemetry stream whose response changes on
// every call.
type sequencedHTTP struct {
	t        *testing.T
	bodies   []string
	requests []sdk.HTTPRequest
}

func (s *sequencedHTTP) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	s.requests = append(s.requests, req)
	if len(s.requests) > len(s.bodies) {
		s.t.Fatalf("unexpected extra request %d to %s", len(s.requests), req.URL)
	}
	return &sdk.HTTPResponse{Status: 200, Body: []byte(s.bodies[len(s.requests)-1])}, nil
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return raw
}
