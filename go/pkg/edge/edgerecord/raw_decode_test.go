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
	"errors"
	"testing"
)

func TestDecodeClientMessageOwnsRawEnvelope(t *testing.T) {
	// Empty lane-open is wire-valid; lane semantics are a subsequent stage.
	control := []byte{10, 0}
	if _, err := DecodeClientMessage(control); err != nil {
		t.Fatal(err)
	}
	for _, raw := range [][]byte{nil, {10}, {10, 128}, {10, 0, 10, 0}, {10, 0, 18, 0}, {11, 12}, {10, 0, 24, 0}, {0}} {
		if _, err := DecodeClientMessage(raw); !errors.Is(err, ErrRecordDecode) {
			t.Fatalf("%x: %v", raw, err)
		}
	}
	// An otherwise valid frame with an unknown field is refused recursively.
	if _, err := DecodeClientMessage([]byte{18, 3, 160, 6, 1}); !errors.Is(err, ErrUnknownFields) {
		t.Fatal(err)
	}
}
