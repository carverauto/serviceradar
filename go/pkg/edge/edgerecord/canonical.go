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
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// MaxRecordBytes is the hard ceiling on one encoded EdgeRecordV1 (512 KiB body).
const MaxRecordBytes = 512 * 1024

// MaxPayloadBytes bounds the inner canonical contract payload. The full record
// (envelope + payload) must still fit MaxRecordBytes; this is a defensive
// per-field ceiling.
const MaxPayloadBytes = 512 * 1024

// CanonicalRecordBytes returns the deterministic canonical encoding of a record.
func CanonicalRecordBytes(r *edgev1.EdgeRecordV1) ([]byte, error) {
	return proto.MarshalOptions{Deterministic: true}.Marshal(r)
}

// DecodeRecord decodes EdgeRecordV1 bytes for field-level validation. It rejects
// oversize input and retained unknown fields (recursively) but does NOT impose
// byte-canonicity: protobuf has no canonical wire form, so a decode->re-encode->
// bytes.Equal admission would reject valid records from any conforming encoder and
// is prohibited by the record-identity model. Identity is carried by record_sha256
// over the EXACT received bytes (the physical artifact) and by the field-framed
// semantic-envelope digest -- never by re-encode equality. Callers MUST hash the
// original bytes, never a re-encoding.
func DecodeRecord(b []byte) (*edgev1.EdgeRecordV1, error) {
	if len(b) == 0 {
		return nil, ErrRecordBytes
	}
	if len(b) > MaxRecordBytes {
		return nil, ErrRecordTooLarge
	}
	var r edgev1.EdgeRecordV1
	if err := proto.Unmarshal(b, &r); err != nil {
		return nil, ErrRecordDecode
	}
	if hasUnknownFields(&r) {
		return nil, ErrUnknownFields
	}
	return &r, nil
}

// hasUnknownFields reports whether m (or any nested message) retained unknown
// protobuf fields. A record that a later reader might reinterpret is rejected.
func hasUnknownFields(m proto.Message) bool {
	rm := m.ProtoReflect()
	if len(rm.GetUnknown()) > 0 {
		return true
	}
	found := false
	rm.Range(func(fd protoreflect.FieldDescriptor, v protoreflect.Value) bool {
		switch {
		case fd.IsMap():
			if fd.MapValue().Kind() == protoreflect.MessageKind {
				v.Map().Range(func(_ protoreflect.MapKey, mv protoreflect.Value) bool {
					if hasUnknownFields(mv.Message().Interface()) {
						found = true
						return false
					}
					return true
				})
			}
		case fd.IsList():
			if fd.Kind() == protoreflect.MessageKind {
				list := v.List()
				for i := 0; i < list.Len(); i++ {
					if hasUnknownFields(list.Get(i).Message().Interface()) {
						found = true
						break
					}
				}
			}
		case fd.Kind() == protoreflect.MessageKind:
			if hasUnknownFields(v.Message().Interface()) {
				found = true
			}
		}
		return !found
	})
	return found
}
