package sdk

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

// Credential broker inject types accepted by ServiceRadar core's integration
// descriptor validator and applied by the agent host. The host injects the
// credential into the outbound request; the plugin never reads the secret.
const (
	CredentialInjectHTTPHeader              = "http_header"
	CredentialInjectHeader                  = "header" // alias of http_header
	CredentialInjectBearerToken             = "bearer_token"
	CredentialInjectBasicAuth               = "basic_auth"
	CredentialInjectHTTPBasicAuth           = "http_basic_auth" // alias of basic_auth
	CredentialInjectQuery                   = "query"
	CredentialInjectQueryParam              = "query_param" // alias of query
	CredentialInjectHTTPQuery               = "http_query"  // alias of query
	CredentialInjectFormURLEncoded          = "form_urlencoded"
	CredentialInjectOAuth2PasswordBearer    = "oauth2_password_bearer"
	CredentialInjectOAuth2ClientCredentials = "oauth2_client_credentials"
)

// Inject spec keys the host reads. field_<credential field> maps a stored
// credential field to a form field; fixed_<form field> sends a literal value.
const (
	CredentialInjectKeyType             = "type"
	CredentialInjectKeyName             = "name"
	CredentialInjectKeyScheme           = "scheme"
	CredentialInjectKeyMethod           = "method"
	CredentialInjectKeyHost             = "host"
	CredentialInjectKeyPath             = "path"
	CredentialInjectKeyAllowInsecureTLS = "allow_insecure_tls"
	CredentialInjectKeyTokenMethod      = "token_method"
	CredentialInjectKeyTokenHost        = "token_host"
	CredentialInjectKeyTokenPort        = "token_port"
	CredentialInjectKeyTokenPath        = "token_path"
	CredentialInjectFieldPrefix         = "field_"
	CredentialInjectFixedPrefix         = "fixed_"
)

const (
	oauth2FormGrantType         = "grant_type"
	oauth2FormClientID          = "client_id"
	oauth2FormClientSecret      = "client_secret"
	oauth2GrantClientCredential = "client_credentials"
)

var errInvalidOAuth2ClientCredentialsInject = errors.New("invalid oauth2_client_credentials inject spec")

// CredentialBrokerAllow is the request scope a credential broker grant may be
// applied to. The host selects a grant only when the request matches it.
type CredentialBrokerAllow struct {
	Schemes []string `json:"schemes,omitempty"`
	Methods []string `json:"methods,omitempty"`
	Paths   []string `json:"paths,omitempty"`
	Hosts   []string `json:"hosts,omitempty"`
	Ports   []int    `json:"ports,omitempty"`
}

// InjectType returns the normalized inject type, or "" when none is set.
func (g CredentialBrokerGrant) InjectType() string {
	return strings.ToLower(strings.TrimSpace(g.InjectSpec()[CredentialInjectKeyType]))
}

// InjectSpec returns the inject map as the host reads it: every value is a
// string. Non-string JSON values are formatted, matching core's normalization.
func (g CredentialBrokerGrant) InjectSpec() map[string]string {
	spec := make(map[string]string, len(g.Inject))
	for key, value := range g.Inject {
		switch typed := value.(type) {
		case string:
			spec[key] = typed
		case nil:
		default:
			spec[key] = fmt.Sprint(typed)
		}
	}
	return spec
}

// OAuth2ClientCredentialsInject is a typed builder for an
// oauth2_client_credentials inject spec. The host exchanges the stored client
// credentials at the token endpoint and sends the resulting access token as
// Authorization: Bearer on requests the grant covers.
type OAuth2ClientCredentialsInject struct {
	// TokenMethod must be POST, the only method the host exchanges with.
	TokenMethod string
	// TokenHost, TokenPort and TokenPath locate the https token endpoint.
	TokenHost string
	TokenPort int
	TokenPath string
	// Fields maps a stored credential field to the form field it fills.
	Fields map[string]string
	// Fixed maps a form field to a literal value, such as grant_type or scope.
	Fixed map[string]string
	// Method, Host and Path, when set, restrict injection to one exact request.
	Method string
	Host   string
	Path   string
	// AllowInsecureTLS permits the grant on requests that skip TLS verification.
	AllowInsecureTLS bool
}

// NewOAuth2ClientCredentialsInject returns a spec that posts client_id and
// client_secret from the stored credential with grant_type=client_credentials.
func NewOAuth2ClientCredentialsInject(tokenHost string, tokenPort int, tokenPath string) OAuth2ClientCredentialsInject {
	return OAuth2ClientCredentialsInject{
		TokenMethod: http.MethodPost,
		TokenHost:   tokenHost,
		TokenPort:   tokenPort,
		TokenPath:   tokenPath,
		Fields: map[string]string{
			oauth2FormClientID:     oauth2FormClientID,
			oauth2FormClientSecret: oauth2FormClientSecret,
		},
		Fixed: map[string]string{oauth2FormGrantType: oauth2GrantClientCredential},
	}
}

// WithField maps a stored credential field onto a token form field.
func (s OAuth2ClientCredentialsInject) WithField(credentialField, formField string) OAuth2ClientCredentialsInject {
	s.Fields = cloneStringMap(s.Fields)
	s.Fields[credentialField] = formField
	return s
}

// WithFixed sends a literal token form field.
func (s OAuth2ClientCredentialsInject) WithFixed(formField, value string) OAuth2ClientCredentialsInject {
	s.Fixed = cloneStringMap(s.Fixed)
	s.Fixed[formField] = value
	return s
}

// WithScope sends a fixed OAuth2 scope with the token request.
func (s OAuth2ClientCredentialsInject) WithScope(scope string) OAuth2ClientCredentialsInject {
	return s.WithFixed("scope", scope)
}

// WithRequestTarget restricts injection to one exact method, host and path.
func (s OAuth2ClientCredentialsInject) WithRequestTarget(method, host, path string) OAuth2ClientCredentialsInject {
	s.Method = method
	s.Host = host
	s.Path = path
	return s
}

// Validate applies the checks the host runs before a token exchange.
func (s OAuth2ClientCredentialsInject) Validate() error {
	_, err := s.Spec()
	return err
}

// Spec returns the validated inject map with the exact keys the host reads.
func (s OAuth2ClientCredentialsInject) Spec() (map[string]string, error) {
	spec := map[string]string{
		CredentialInjectKeyType:        CredentialInjectOAuth2ClientCredentials,
		CredentialInjectKeyTokenMethod: strings.ToUpper(strings.TrimSpace(s.TokenMethod)),
		CredentialInjectKeyTokenHost:   strings.TrimSpace(s.TokenHost),
		CredentialInjectKeyTokenPort:   strconv.Itoa(s.TokenPort),
		CredentialInjectKeyTokenPath:   strings.TrimSpace(s.TokenPath),
	}
	for key, value := range map[string]string{
		CredentialInjectKeyMethod: strings.ToUpper(strings.TrimSpace(s.Method)),
		CredentialInjectKeyHost:   strings.TrimSpace(s.Host),
		CredentialInjectKeyPath:   strings.TrimSpace(s.Path),
	} {
		if value != "" {
			spec[key] = value
		}
	}
	if s.AllowInsecureTLS {
		spec[CredentialInjectKeyAllowInsecureTLS] = "true"
	}
	for source, target := range s.Fields {
		spec[CredentialInjectFieldPrefix+source] = target
	}
	for field, value := range s.Fixed {
		spec[CredentialInjectFixedPrefix+field] = value
	}

	if err := validateOAuth2ClientCredentialsSpec(spec); err != nil {
		return nil, err
	}
	return spec, nil
}

// Inject returns the spec in the shape of CredentialBrokerGrant.Inject.
func (s OAuth2ClientCredentialsInject) Inject() (map[string]any, error) {
	spec, err := s.Spec()
	if err != nil {
		return nil, err
	}
	inject := make(map[string]any, len(spec))
	for key, value := range spec {
		inject[key] = value
	}
	return inject, nil
}

// validateOAuth2ClientCredentialsSpec mirrors the host's token URL and form
// checks.
func validateOAuth2ClientCredentialsSpec(spec map[string]string) error {
	_, _, err := oauth2ClientCredentialsFormFields(spec)
	return err
}

// oauth2ClientCredentialsFormFields returns form field -> credential field for
// field_* entries and form field -> literal for fixed_* entries.
func oauth2ClientCredentialsFormFields(spec map[string]string) (fields, fixed map[string]string, err error) {
	invalid := func(reason string) (map[string]string, map[string]string, error) {
		return nil, nil, fmt.Errorf("%w: %s", errInvalidOAuth2ClientCredentialsInject, reason)
	}
	if !strings.EqualFold(strings.TrimSpace(spec[CredentialInjectKeyType]), CredentialInjectOAuth2ClientCredentials) {
		return invalid("type must be " + CredentialInjectOAuth2ClientCredentials)
	}
	if !strings.EqualFold(strings.TrimSpace(spec[CredentialInjectKeyTokenMethod]), http.MethodPost) {
		return invalid("token_method must be POST")
	}
	host := strings.TrimSpace(spec[CredentialInjectKeyTokenHost])
	path := strings.TrimSpace(spec[CredentialInjectKeyTokenPath])
	port, portErr := strconv.Atoi(strings.TrimSpace(spec[CredentialInjectKeyTokenPort]))
	switch {
	case host == "" || strings.ContainsAny(host, "/@?#"):
		return invalid("token_host must be a bare host")
	case portErr != nil || port < 1 || port > 65535:
		return invalid("token_port must be between 1 and 65535")
	case path == "" || path[0] != '/' || strings.ContainsAny(path, "?#"):
		return invalid("token_path must be an absolute path without query or fragment")
	}

	fields = map[string]string{}
	fixed = map[string]string{}
	for key, target := range spec {
		source, ok := strings.CutPrefix(key, CredentialInjectFieldPrefix)
		if !ok {
			continue
		}
		target = strings.TrimSpace(target)
		if !validInjectSuffix(source) || target == "" {
			return invalid("field_* entries need a credential field and a form field")
		}
		if _, dup := fields[target]; dup {
			return invalid("form field " + target + " is set twice")
		}
		fields[target] = source
	}
	for key, value := range spec {
		field, ok := strings.CutPrefix(key, CredentialInjectFixedPrefix)
		if !ok {
			continue
		}
		if !validInjectSuffix(field) {
			return invalid("fixed_* entries need a form field")
		}
		if _, dup := fields[field]; dup {
			return invalid("form field " + field + " is set twice")
		}
		fixed[field] = value
	}
	if fixed[oauth2FormGrantType] != oauth2GrantClientCredential {
		return invalid("fixed_grant_type must be client_credentials")
	}
	for _, required := range []string{oauth2FormClientID, oauth2FormClientSecret} {
		if _, ok := fields[required]; !ok && fixed[required] == "" {
			return invalid(required + " must be mapped from a credential field")
		}
	}
	return fields, fixed, nil
}

// validInjectSuffix mirrors core's ^(field|fixed)_[a-z0-9_.-]+$ key rule.
func validInjectSuffix(value string) bool {
	if value == "" {
		return false
	}
	for _, c := range value {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '_' && c != '.' && c != '-' {
			return false
		}
	}
	return true
}

func cloneStringMap(in map[string]string) map[string]string {
	out := make(map[string]string, len(in)+1)
	for key, value := range in {
		out[key] = value
	}
	return out
}
