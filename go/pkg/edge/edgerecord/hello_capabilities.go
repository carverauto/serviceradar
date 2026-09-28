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
	"cmp"
	"errors"
	"fmt"
	"slices"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

var (
	ErrCapabilityConflict  = errors.New("edgerecord: Hello capability conflict")
	ErrCapabilityDuplicate = errors.New("edgerecord: duplicate Hello capability")
)

// CompareHelloCapabilities enforces equal-or-reject across the two Hello RPCs.
// Every repeated field is a set; duplicates are refused even when both inputs
// contain the same duplicate. Scalar fields and contract tuples must agree.
// Nil means no edge support: two absent advertisements agree, absent and present
// do not. Neither input is modified.
//
// This compares decoded advertisements, not admission or authorization. Callers
// still own raw Hello bounds, supported-version negotiation and grant checks.
func CompareHelloCapabilities(a, b *edgev1.EdgeRecordCapabilitiesV1) error {
	left, err := helloCapabilitySet(a)
	if err != nil {
		return err
	}
	right, err := helloCapabilitySet(b)
	if err != nil {
		return err
	}
	if !proto.Equal(left, right) {
		return ErrCapabilityConflict
	}
	return nil
}

// Normalize all repeated fields from the descriptor so a future set cannot
// accidentally acquire order-sensitive equality. Deterministic protobuf is only
// a sorting key here, never an identity digest or a signed transcript.
func helloCapabilitySet(c *edgev1.EdgeRecordCapabilitiesV1) (*edgev1.EdgeRecordCapabilitiesV1, error) {
	if c == nil {
		return nil, nil
	}
	out := proto.Clone(c).(*edgev1.EdgeRecordCapabilitiesV1)
	m := out.ProtoReflect()
	fields := m.Descriptor().Fields()
	for i := 0; i < fields.Len(); i++ {
		f := fields.Get(i)
		if !f.IsList() {
			continue
		}
		list := m.Mutable(f).List()
		entries := make([]helloSetEntry, list.Len())
		for j := 0; j < list.Len(); j++ {
			value := list.Get(j)
			var key string
			if f.Kind() == protoreflect.MessageKind {
				encoded, err := (proto.MarshalOptions{Deterministic: true}).Marshal(value.Message().Interface())
				if err != nil {
					return nil, fmt.Errorf("%w: %s", ErrCapabilityConflict, f.Name())
				}
				key = string(encoded)
			} else {
				key = fmt.Sprint(value.Interface())
			}
			entries[j] = helloSetEntry{key: key, value: value}
		}
		slices.SortFunc(entries, func(a, b helloSetEntry) int { return cmp.Compare(a.key, b.key) })
		for j, entry := range entries {
			if j > 0 && entry.key == entries[j-1].key {
				return nil, fmt.Errorf("%w: %s", ErrCapabilityDuplicate, f.Name())
			}
			list.Set(j, entry.value)
		}
	}
	return out, nil
}

type helloSetEntry struct {
	key   string
	value protoreflect.Value
}
