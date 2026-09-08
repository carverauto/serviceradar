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
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"net/url"
	"strings"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

func (e *pluginExecution) authorizeCredentialBrokerHTTPRequestBody(
	grant *credentialBrokerGrant,
	method string,
	requestURL *url.URL,
	pluginBody []byte,
) ([]byte, string, error) {
	if grant == nil {
		return pluginBody, "", nil
	}

	schema := strings.TrimSpace(grant.Schema)
	strictAWX := strings.EqualFold(strings.TrimSpace(grant.GrantType), "awx_oauth2_token")
	if credentialBrokerHTTPMethodSafe(method) {
		if (strictAWX || schema == coreaddon.CredentialBrokerGrantSchemaV2) && len(pluginBody) != 0 {
			return nil, "", errCredentialBrokerGrantDenied
		}
		return pluginBody, "", nil
	}

	if schema != coreaddon.CredentialBrokerGrantSchemaV2 {
		if strictAWX {
			return nil, "", errCredentialBrokerGrantDenied
		}
		return pluginBody, "", nil
	}

	policy := grant.Allow.RequestBody
	if err := validateCredentialBrokerRequestBodyPolicy(policy); err != nil {
		return nil, "", err
	}

	switch policy.Mode {
	case coreaddon.CredentialBrokerRequestBodyModeEmpty:
		if len(pluginBody) != 0 {
			return nil, "", errCredentialBrokerGrantDenied
		}
		return nil, policy.ContentType, nil

	case coreaddon.CredentialBrokerRequestBodyModeBoundBytes:
		if e == nil || len(e.authorizedRequestBody) == 0 ||
			len(e.authorizedRequestBody) > policy.MaxBytes {
			return nil, "", errCredentialBrokerGrantDenied
		}
		expectedDigest, err := hex.DecodeString(policy.SHA256)
		if err != nil || len(expectedDigest) != sha256.Size {
			return nil, "", errInvalidCredentialBrokerGrant
		}
		actualDigest := sha256.Sum256(e.authorizedRequestBody)
		if subtle.ConstantTimeCompare(actualDigest[:], expectedDigest) != 1 {
			return nil, "", errCredentialBrokerGrantDenied
		}
		return e.authorizedRequestBody, policy.ContentType, nil

	case coreaddon.CredentialBrokerRequestBodyModeTrustedRewrite:
		if policy.Handler != coreaddon.CredentialBrokerAWXCallbackBodyHandler ||
			e == nil || e.awxCallbackCredential == nil ||
			requestURL == nil || !awxCredentialEndpoint(requestURL) ||
			len(pluginBody) == 0 || len(pluginBody) > policy.MaxBytes {
			return nil, "", errCredentialBrokerGrantDenied
		}
		return pluginBody, policy.ContentType, nil

	default:
		return nil, "", errInvalidCredentialBrokerGrant
	}
}

func (e *pluginExecution) reserveCredentialBrokerMutation(
	grant *credentialBrokerGrant,
	method string,
) error {
	if grant == nil || credentialBrokerHTTPMethodSafe(method) ||
		strings.TrimSpace(grant.Schema) != coreaddon.CredentialBrokerGrantSchemaV2 {
		return nil
	}
	if e == nil || strings.TrimSpace(grant.GrantID) == "" ||
		validateCredentialBrokerRequestBodyPolicy(grant.Allow.RequestBody) != nil {
		return errInvalidCredentialBrokerGrant
	}

	grantID := strings.TrimSpace(grant.GrantID)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.credentialGrantMutationUses == nil {
		e.credentialGrantMutationUses = make(map[string]int)
	}
	if e.credentialGrantMutationUses[grantID] >= grant.Allow.RequestBody.MaxMutations {
		return errCredentialBrokerGrantDenied
	}
	e.credentialGrantMutationUses[grantID]++
	return nil
}

func enforceCredentialBrokerContentType(request *http.Request, contentType string) {
	if request == nil || strings.TrimSpace(contentType) == "" {
		return
	}
	request.Header.Del("Content-Type")
	request.Header.Set("Content-Type", contentType)
	request.Header.Del("Content-Length")
	request.Header.Del("Transfer-Encoding")
}
