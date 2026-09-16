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

package edgerecord

import "errors"

// MaxPrincipalBytes bounds an authenticated component-id principal.
const MaxPrincipalBytes = 128

// ErrPrincipal is returned for an authenticated principal that violates the frozen
// encoding (#4710 decision 5).
var ErrPrincipal = errors.New("edgerecord: invalid authenticated principal")

// ValidateAuthenticatedPrincipal enforces the frozen authenticated-principal encoding: the
// exact case-sensitive ASCII bytes the authenticated component-id resolver returns, charset
// [A-Za-z0-9_-], length 1..MaxPrincipalBytes. No trimming, lowercasing, UUID text/binary
// conversion, or Unicode normalization is applied. The SAME value is producer_context's
// origin_principal_id, is bound identically into every typed claim, and feeds the
// publication-identity transport headers (Nats-Msg-Id, Sr-Edge-Delivery-Id, provenance).
func ValidateAuthenticatedPrincipal(id []byte) error {
	if len(id) < 1 || len(id) > MaxPrincipalBytes {
		return ErrPrincipal
	}
	for _, c := range id {
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_', c == '-':
		default:
			return ErrPrincipal
		}
	}
	return nil
}
