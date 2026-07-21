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
)

type credentialBrokerOAuth2TokenResponse struct {
	AccessToken string `json:"access_token"`
}

func (e *pluginExecution) applyCredentialBrokerOAuth2PasswordBearer(
	ctx context.Context,
	req *http.Request,
	grant credentialBrokerGrant,
	material CredentialBrokerMaterial,
) error {
	if e == nil || e.manager == nil || req == nil || req.URL == nil ||
		!credentialBrokerInjectionTargetsRequest(req, grant.Inject) {
		return errCredentialBrokerTokenExchangeInvalid
	}

	tokenURL, err := credentialBrokerTokenURL(grant.Inject)
	if err != nil {
		return err
	}
	form, err := credentialBrokerTokenForm(grant.Inject, material)
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

	client := pluginHTTPClient(e.manager.httpClient, false, pluginDefaultHTTPTimeout)
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
	if form.Get("username") == "" || form.Get("password") == "" || form.Get("grant_type") != "password" {
		return nil, errCredentialBrokerTokenExchangeInvalid
	}
	return form, nil
}
