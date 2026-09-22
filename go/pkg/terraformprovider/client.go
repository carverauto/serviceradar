// Package terraformprovider implements the public ServiceRadar configuration API client for Terraform.
package terraformprovider

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
)

const maxResponseBytes = 2 << 20

// Keep diagnostics static: transport and API errors can contain credential material.
var (
	errInvalidEndpoint     = errors.New("endpoint must be an HTTPS origin without credentials, a path, query, or fragment")
	errAmbiguousCredential = errors.New("configure exactly one of api_token (OAuth/access bearer) or api_key (user-bound API key)")
	errInvalidCredential   = errors.New("the configured API credential must be nonempty and contain no line breaks")
	errSystemTrustStore    = errors.New("could not load the system CA trust store")
	errInvalidCA           = errors.New("ca_certificate contains no valid PEM certificate")
	errRequestEncoding     = errors.New("could not encode the ServiceRadar request")
	errRequestConstruction = errors.New("could not construct the ServiceRadar request")
	errRequestIncomplete   = errors.New("ServiceRadar request did not complete; a mutation may have succeeded; retain the idempotency key and reconcile before retrying")
	errInvalidResponse     = errors.New("ServiceRadar returned an invalid or oversized resource response")
	errInvalidIdentity     = errors.New("ServiceRadar returned an invalid resource identity")
	errMismatchedIdentity  = errors.New("ServiceRadar returned a different resource identity than requested")
	errMissingETag         = errors.New("ServiceRadar response has no ETag; the declarative configuration API is required")
)

type apiClient struct {
	endpoint   string
	authHeader string
	authValue  string
	http       *http.Client
}

type apiObject struct {
	fields map[string]any
	etag   string
}

type apiError struct{ status int }

func (e *apiError) Error() string {
	// An upstream error may echo submitted credentials. Never put response bodies,
	// request bodies, headers, or transport errors in Terraform diagnostics.
	switch e.status {
	case http.StatusUnauthorized, http.StatusForbidden:
		return "ServiceRadar denied the request; check the account permissions and token capabilities"
	case http.StatusConflict:
		return "ServiceRadar rejected a conflicting request or a deletion with active references"
	case http.StatusPreconditionFailed, http.StatusPreconditionRequired:
		return "ServiceRadar rejected a stale or missing resource version; refresh the plan before retrying"
	default:
		return fmt.Sprintf("ServiceRadar returned HTTP %d; inspect the server's sanitized audit record", e.status)
	}
}

func newAPIClient(endpoint, apiToken, apiKey string, caPEM []byte) (*apiClient, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, errInvalidEndpoint
	}
	if (apiToken == "") == (apiKey == "") {
		return nil, errAmbiguousCredential
	}
	authHeader, authValue := "Authorization", "Bearer "+apiToken
	material := apiToken
	if apiKey != "" {
		authHeader, authValue, material = "X-API-Key", apiKey, apiKey
	}
	if strings.TrimSpace(material) == "" || strings.ContainsAny(material, "\r\n") {
		return nil, errInvalidCredential
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if len(caPEM) > 0 {
		roots, err := x509.SystemCertPool()
		if err != nil {
			return nil, errSystemTrustStore
		}
		if !roots.AppendCertsFromPEM(caPEM) {
			return nil, errInvalidCA
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	}
	return &apiClient{
		endpoint: strings.TrimSuffix(endpoint, "/"), authHeader: authHeader, authValue: authValue,
		http: &http.Client{Transport: transport, Timeout: 45 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }},
	}, nil
}

func (c *apiClient) request(ctx context.Context, method, route, etag, key string, body map[string]any) (apiObject, error) {
	var result apiObject
	var encoded []byte
	if body != nil {
		var err error
		encoded, err = json.Marshal(body)
		if err != nil {
			return result, errRequestEncoding
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, c.endpoint+"/api/admin/"+route, bytes.NewReader(encoded))
	if err != nil {
		return result, errRequestConstruction
	}
	req.Header.Set(c.authHeader, c.authValue)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if etag != "" {
		req.Header.Set("If-Match", etag)
	}
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	res, err := c.http.Do(req)
	if err != nil {
		return result, errRequestIncomplete
	}
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return result, &apiError{status: res.StatusCode}
	}
	if method == http.MethodDelete && res.StatusCode == http.StatusNoContent {
		return result, nil
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, maxResponseBytes+1))
	if err != nil || len(data) > maxResponseBytes || json.Unmarshal(data, &result.fields) != nil || result.fields == nil {
		return result, errInvalidResponse
	}
	id, ok := result.fields["id"].(string)
	parsed, identityErr := uuid.Parse(id)
	if !ok || identityErr != nil || parsed.String() != id {
		return result, errInvalidIdentity
	}
	parts := strings.Split(route, "/")
	if len(parts) > 1 && parts[1] != id {
		return result, errMismatchedIdentity
	}
	result.etag = res.Header.Get("ETag")
	if result.etag == "" {
		return result, errMissingETag
	}
	return result, nil
}

func isNotFound(err error) bool {
	var apiErr *apiError
	return errors.As(err, &apiErr) && apiErr.status == http.StatusNotFound
}
