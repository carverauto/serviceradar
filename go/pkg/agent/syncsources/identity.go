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

package syncsources

import (
	"strings"
	"unicode"
)

// ScopedIntegrationID mints a source-scoped integration identifier for the
// generic identity contract: "<type>:<scope>:<kind>:<native-id>"
// (for example "armis:main:device:18497", mirroring the NetBox driver's
// "netbox:<source>:device:<id>" form).
//
// The scope must distinguish one provider instance from another; a bare
// native ID is not a device identity because two instances routinely mint
// the same numbers. Core accepts a provider integration_id only when it
// carries its own scope, so drivers must route identity evidence through
// this helper instead of emitting the raw native ID as integration_id.
//
// It returns "" when any segment is empty after normalization, in which
// case the caller must fall back to legacy behavior (core rejects the
// unscoped value rather than merging on it).
func ScopedIntegrationID(sourceType, scope, objectKind, nativeID string) string {
	sourceType = NormalizeType(sourceType)
	scope = NormalizeIdentityScope(scope)
	objectKind = strings.ToLower(strings.TrimSpace(objectKind))
	nativeID = strings.TrimSpace(nativeID)
	if sourceType == "" || scope == "" || objectKind == "" || nativeID == "" {
		return ""
	}
	return sourceType + ":" + scope + ":" + objectKind + ":" + nativeID
}

// NormalizeIdentityScope canonicalizes an operator-configured source scope
// (a sync service ID, source key, or partition) so it is safe to embed in a
// scoped integration identifier: trimmed, lowercased, with runs of colons
// and whitespace collapsed to a single dash. Colons are the identifier
// segment separator, so they must never survive inside a segment.
func NormalizeIdentityScope(scope string) string {
	fields := strings.FieldsFunc(strings.ToLower(strings.TrimSpace(scope)), func(r rune) bool {
		return r == ':' || unicode.IsSpace(r)
	})
	return strings.Join(fields, "-")
}
