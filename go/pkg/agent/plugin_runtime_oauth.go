/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const (
	credentialBrokerTokenResponseLimit = 64 * 1024
	credentialBrokerTokenLimit         = 8 * 1024

	// OAuth2 password-grant form fields (goconst: reused across credential broker inject paths).
	credentialFormFieldUsername  = "username"
	credentialFormFieldPassword  = "password"
	credentialFormFieldGrantType = "grant_type"
	// Same wire value as the password form field for RFC 6749 password grant.
	oauth2GrantTypePassword = credentialFormFieldPassword

	// RFC 6749 section 4.4 client-credentials grant.
	credentialFormFieldClientID      = "client_id"
	credentialFormFieldClientSecret  = "client_secret"
	oauth2GrantTypeClientCredentials = "client_credentials"

	injectTypeOAuth2PasswordBearer    = "oauth2_password_bearer"
	injectTypeOAuth2ClientCredentials = "oauth2_client_credentials"
)

// oauth2GrantShape describes the one grant an inject type performs. Both shapes
// run the identical exchange - same URL derivation, same transport, same
// response handling - and differ only in which form fields the host requires the
// grant to carry. Keeping that difference in data rather than in a second copy
// of the exchange is what stops the two paths drifting apart, which for a
// credential path means one of them silently losing a check the other has.
type oauth2GrantShape struct {
	grantType      string
	requiredFields []string
}

//nolint:gochecknoglobals // closed lookup table, read-only after init
var oauth2GrantShapes = map[string]oauth2GrantShape{
	injectTypeOAuth2PasswordBearer: {
		grantType:      oauth2GrantTypePassword,
		requiredFields: []string{credentialFormFieldUsername, credentialFormFieldPassword},
	},
	injectTypeOAuth2ClientCredentials: {
		grantType:      oauth2GrantTypeClientCredentials,
		requiredFields: []string{credentialFormFieldClientID, credentialFormFieldClientSecret},
	},
}

// oauth2GrantShapeFor reports the grant an inject type performs, and whether the
// type is an OAuth2 token-exchange type at all.
func oauth2GrantShapeFor(injectType string) (oauth2GrantShape, bool) {
	shape, ok := oauth2GrantShapes[strings.ToLower(strings.TrimSpace(injectType))]
	return shape, ok
}

type credentialBrokerOAuth2TokenResponse struct {
	AccessToken string `json:"access_token"`
}

func (e *pluginExecution) applyCredentialBrokerOAuth2Bearer(
	ctx context.Context,
	req *http.Request,
	grant credentialBrokerGrant,
	material CredentialBrokerMaterial,
	shape oauth2GrantShape,
	insecureSkipVerify bool,
) error {
	if e == nil || e.manager == nil || req == nil || req.URL == nil ||
		!credentialBrokerInjectionTargetsRequest(req, grant.Inject) {
		return errCredentialBrokerTokenExchangeInvalid
	}

	tokenURL, err := credentialBrokerTokenURL(grant.Inject)
	if err != nil {
		return err
	}
	form, err := credentialBrokerTokenForm(grant.Inject, material, shape)
	if err != nil {
		return err
	}

	tokenReq, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		tokenURL.String(),
		strings.NewReader(form.Encode()),
	)
	if err != nil {
		return errCredentialBrokerTokenExchangeInvalid
	}
	tokenReq.Header.Set("Accept", "application/json")
	tokenReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	client := pluginHTTPClient(e.manager.httpClient, insecureSkipVerify, pluginDefaultHTTPTimeout)
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}

	response, err := client.Do(tokenReq)
	if err != nil {
		return errCredentialBrokerTokenExchangeFailed
	}
	defer func() {
		_ = response.Body.Close()
	}()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return errCredentialBrokerTokenExchangeFailed
	}

	body, err := io.ReadAll(io.LimitReader(response.Body, credentialBrokerTokenResponseLimit+1))
	if err != nil || len(body) > credentialBrokerTokenResponseLimit {
		clear(body)
		return errCredentialBrokerTokenExchangeFailed
	}
	defer clear(body)

	decoder := json.NewDecoder(bytes.NewReader(body))
	var tokenResponse credentialBrokerOAuth2TokenResponse
	if err := decoder.Decode(&tokenResponse); err != nil {
		return errCredentialBrokerTokenExchangeFailed
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errCredentialBrokerTokenExchangeFailed
	}

	token := strings.TrimSpace(tokenResponse.AccessToken)
	if token == "" || len(token) > credentialBrokerTokenLimit || strings.ContainsAny(token, "\r\n") {
		return errCredentialBrokerTokenExchangeFailed
	}
	req.Header.Set("Authorization", "Bearer "+token)
	return nil
}

func credentialBrokerTokenURL(inject map[string]string) (*url.URL, error) {
	if !strings.EqualFold(strings.TrimSpace(inject["token_method"]), http.MethodPost) {
		return nil, errCredentialBrokerTokenExchangeInvalid
	}
	host := strings.TrimSpace(inject["token_host"])
	path := strings.TrimSpace(inject["token_path"])
	port, err := strconv.Atoi(strings.TrimSpace(inject["token_port"]))
	if err != nil || port < 1 || port > 65535 || host == "" || path == "" || path[0] != '/' ||
		strings.ContainsAny(host, "/@?#") || strings.ContainsAny(path, "?#") {
		return nil, errCredentialBrokerTokenExchangeInvalid
	}

	urlHost := host
	if port != 443 {
		urlHost = net.JoinHostPort(host, strconv.Itoa(port))
	}
	return &url.URL{Scheme: httpsScheme, Host: urlHost, Path: path}, nil
}

func credentialBrokerTokenForm(
	inject map[string]string,
	material CredentialBrokerMaterial,
	shape oauth2GrantShape,
) (url.Values, error) {
	form := make(url.Values)
	for key, targetField := range inject {
		if !strings.HasPrefix(key, "field_") {
			continue
		}
		sourceField := strings.TrimSpace(strings.TrimPrefix(key, "field_"))
		targetField = strings.TrimSpace(targetField)
		value := credentialMaterialFieldValue(material, sourceField)
		if sourceField == "" || targetField == "" || value == "" || form.Has(targetField) {
			return nil, errCredentialBrokerTokenExchangeInvalid
		}
		form.Set(targetField, value)
	}
	for key, value := range inject {
		if !strings.HasPrefix(key, "fixed_") {
			continue
		}
		field := strings.TrimSpace(strings.TrimPrefix(key, "fixed_"))
		if field == "" || form.Has(field) {
			return nil, errCredentialBrokerTokenExchangeInvalid
		}
		form.Set(field, value)
	}
	if form.Get(credentialFormFieldGrantType) != shape.grantType {
		return nil, errCredentialBrokerTokenExchangeInvalid
	}
	for _, field := range shape.requiredFields {
		if form.Get(field) == "" {
			return nil, errCredentialBrokerTokenExchangeInvalid
		}
	}
	return form, nil
}
