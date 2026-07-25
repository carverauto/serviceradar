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

import (
	"bytes"
	"testing"
)

func TestValidateAuthenticatedPrincipal(t *testing.T) {
	for _, id := range [][]byte{[]byte("a"), []byte("agent-0"), []byte("Agent_0-Z9"), bytes.Repeat([]byte("x"), MaxPrincipalBytes)} {
		if err := ValidateAuthenticatedPrincipal(id); err != nil {
			t.Fatalf("valid principal %q rejected: %v", id, err)
		}
	}
	for _, id := range [][]byte{
		nil, // empty
		bytes.Repeat([]byte("x"), MaxPrincipalBytes+1), // too long
		[]byte("has space"),
		[]byte("bad!"),
		{0x00},
		{0xFF},
	} {
		if err := ValidateAuthenticatedPrincipal(id); err == nil {
			t.Fatalf("invalid principal %q accepted", id)
		}
	}
}

// A record whose origin_principal_id is a binary UUID (not an ASCII component-id) is
// rejected: decision 5 requires the authenticated principal be a bounded ASCII token, and
// the typed claim binds the same value.
func TestValidateRecordRejectsBinaryPrincipal(t *testing.T) {
	r := validRecord(t)
	badID := mustUUID(t) // 16 binary bytes -- not [A-Za-z0-9_-]
	r.GetProducerContext().OriginPrincipalId = badID
	r.GetProductionCapability().GetProduction().OriginPrincipalId = badID
	reseal(r)
	if err := ValidateRecord(r); err == nil {
		t.Fatal("record with a binary-UUID origin principal must be rejected")
	}
}
