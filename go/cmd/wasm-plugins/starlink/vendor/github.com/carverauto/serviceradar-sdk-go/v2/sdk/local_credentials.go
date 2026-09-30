//go:build !tinygo

package sdk

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

var (
	errLocalGrantTarget            = errors.New("request is outside the credential grant inject target")
	errLocalGrantInsecureTLS       = errors.New("credential grant does not allow insecure TLS")
	errLocalGrantCredentialMissing = errors.New("local credential field for grant is not set")
)

// LocalOAuth2BearerToken is the synthetic access token the local host injects
// for an oauth2_client_credentials grant. It is derived from the grant
// identity only, never from credential material, so a local HTTPHandler can
// recognize it without a token endpoint.
func LocalOAuth2BearerToken(grant CredentialBrokerGrant) string {
	sum := sha256.Sum256([]byte("serviceradar.local_oauth2\x00" + grant.GrantID + "\x00" + grant.CredentialSecretRef))
	return "local-oauth2." + hex.EncodeToString(sum[:16])
}

// applyLocalCredentialGrants emulates the agent's host-side OAuth2
// client-credentials injection. A grant is selected by its allow scope; a
// selected grant whose inject target, TLS policy or credential fields do not
// fit the request denies it, as on the agent. Requests no grant covers pass
// through unchanged.
func (h *localHostExecution) applyLocalCredentialGrants(request *HTTPRequest) error {
	if len(h.grants) == 0 {
		return nil
	}
	reqURL, err := url.Parse(strings.TrimSpace(request.URL))
	if err != nil || reqURL.Host == "" {
		return errLocalGrantTarget
	}
	method := strings.ToUpper(strings.TrimSpace(request.Method))
	if method == "" {
		method = http.MethodGet
	}

	now := time.Now()
	for _, grant := range h.grants {
		if grant.InjectType() != CredentialInjectOAuth2ClientCredentials ||
			localGrantExpired(grant, now) || !localGrantAllows(grant.Allow, method, reqURL) {
			continue
		}
		spec := grant.InjectSpec()
		if !localInjectTargetsRequest(spec, method, reqURL) {
			return errLocalGrantTarget
		}
		if request.InsecureSkipVerify && !strings.EqualFold(strings.TrimSpace(spec[CredentialInjectKeyAllowInsecureTLS]), "true") {
			return errLocalGrantInsecureTLS
		}
		fields, _, err := oauth2ClientCredentialsFormFields(spec)
		if err != nil {
			return err
		}
		for _, source := range fields {
			if strings.TrimSpace(h.localCredential(source)) == "" {
				return errLocalGrantCredentialMissing
			}
		}

		headers := make(map[string]string, len(request.Headers)+1)
		for key, value := range request.Headers {
			if !strings.EqualFold(key, "Authorization") {
				headers[key] = value
			}
		}
		headers["Authorization"] = "Bearer " + LocalOAuth2BearerToken(grant)
		request.Headers = headers
		return nil
	}
	return nil
}

func (h *localHostExecution) localCredential(field string) string {
	for key, value := range h.credentials {
		if strings.EqualFold(key, field) {
			return value
		}
	}
	return ""
}

func localGrantExpired(grant CredentialBrokerGrant, now time.Time) bool {
	raw := strings.TrimSpace(grant.ExpiresAt)
	if raw == "" {
		return false
	}
	expiresAt, err := time.Parse(time.RFC3339, raw)
	return err != nil || !now.Before(expiresAt)
}

// localGrantAllows mirrors the agent's allow-scope check for non-AWX grants:
// hosts are required, the other lists restrict only when set.
func localGrantAllows(allow *CredentialBrokerAllow, method string, reqURL *url.URL) bool {
	if allow == nil || len(allow.Hosts) == 0 {
		return false
	}
	if len(allow.Schemes) > 0 && !foldedListContains(allow.Schemes, reqURL.Scheme) {
		return false
	}
	if len(allow.Methods) > 0 && !foldedListContains(allow.Methods, method) {
		return false
	}
	path := localEscapedPath(reqURL)
	if len(allow.Paths) > 0 && !localGrantPathAllowed(allow.Paths, path) {
		return false
	}
	if !foldedListContains(allow.Hosts, reqURL.Hostname()) && !foldedListContains(allow.Hosts, reqURL.Host) {
		return false
	}
	if len(allow.Ports) > 0 {
		port := localURLPort(reqURL)
		for _, allowed := range allow.Ports {
			if port != 0 && allowed == port {
				return true
			}
		}
		return false
	}
	return true
}

func localInjectTargetsRequest(spec map[string]string, method string, reqURL *url.URL) bool {
	if expected := strings.TrimSpace(spec[CredentialInjectKeyMethod]); expected != "" && !strings.EqualFold(expected, method) {
		return false
	}
	if expected := strings.TrimSpace(spec[CredentialInjectKeyHost]); expected != "" &&
		!strings.EqualFold(expected, reqURL.Hostname()) && !strings.EqualFold(expected, reqURL.Host) {
		return false
	}
	if expected := strings.TrimSpace(spec[CredentialInjectKeyPath]); expected != "" && expected != localEscapedPath(reqURL) {
		return false
	}
	return true
}

func localGrantPathAllowed(patterns []string, requested string) bool {
	for _, pattern := range patterns {
		pattern = strings.TrimSpace(pattern)
		switch {
		case pattern == "":
			continue
		case strings.HasPrefix(pattern, "=") && strings.TrimPrefix(pattern, "=") == requested:
			return true
		case pattern == requested:
			return true
		case strings.HasSuffix(pattern, "*") && strings.HasPrefix(requested, strings.TrimSuffix(pattern, "*")):
			return true
		case strings.HasSuffix(pattern, "/") && strings.HasPrefix(requested, pattern):
			return true
		}
	}
	return false
}

func localEscapedPath(reqURL *url.URL) string {
	if path := reqURL.EscapedPath(); path != "" {
		return path
	}
	return "/"
}

func localURLPort(reqURL *url.URL) int {
	if raw := reqURL.Port(); raw != "" {
		port, err := strconv.Atoi(raw)
		if err != nil {
			return 0
		}
		return port
	}
	switch strings.ToLower(reqURL.Scheme) {
	case "http":
		return 80
	case "https":
		return 443
	default:
		return 0
	}
}

func foldedListContains(values []string, value string) bool {
	for _, candidate := range values {
		if strings.EqualFold(strings.TrimSpace(candidate), value) {
			return true
		}
	}
	return false
}
