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
	"errors"
	"os"
	"strings"
	"testing"

	monitoring "github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

func helloControl() *edgev1.EdgeRecordCapabilitiesV1 {
	return &edgev1.EdgeRecordCapabilitiesV1{
		ProtocolVersions: []uint32{1, 2}, PayloadFamilies: []edgev1.EdgeRecordPayloadFamily{1, 2},
		Encodings: []edgev1.EdgeRecordEncoding{1}, Compressions: []edgev1.EdgeRecordCompression{1, 2},
		SpoolReaderVersions: []uint32{1, 2}, MaxRecordBytes: MaxRecordBytes,
		MaxDeliveryEnvelopeBytes: MaxDeliveryEnvelopeBytes, MaxFrameBytes: MaxFrameBytes,
		MaxClientMessageBytes: MaxClientMessageBytes, RegistryEpoch: 1,
		RegistrySnapshotSha256: bytes.Repeat([]byte{0x31}, 32),
		OutputContracts: []*edgev1.EdgeSupportedContractV1{
			{ContractId: "example.com/alpha", ContractVersion: 1, ContractBundleSha256: bytes.Repeat([]byte{0x41}, 32)},
			{ContractId: "example.com/beta", ContractVersion: 2, ContractBundleSha256: bytes.Repeat([]byte{0x42}, 32)},
		},
	}
}

func TestHelloCapabilitiesSharedCorpus(t *testing.T) {
	control := helloControl()
	manifest := ""
	check := func(name string, c *edgev1.EdgeRecordCapabilitiesV1, want error) {
		t.Helper()
		before := proto.Clone(c)
		err := CompareHelloCapabilities(control, c)
		if !errors.Is(err, want) {
			t.Fatalf("%s: got %v, want %v", name, err, want)
		}
		if !proto.Equal(before, c) {
			t.Fatalf("%s: mutated input", name)
		}
		raw, err := proto.Marshal(c)
		if err != nil {
			t.Fatal(err)
		}
		filename := "hello_capabilities_" + name + ".bin"
		goldenBytesLocal(t, filename, raw)
		verdict := "equal"
		if errors.Is(want, ErrCapabilityConflict) {
			verdict = "conflict"
		}
		if errors.Is(want, ErrCapabilityDuplicate) {
			verdict = "duplicate"
		}
		manifest += filename + " " + verdict + "\n"
	}
	check("control", control, nil)
	permuted := proto.Clone(control).(*edgev1.EdgeRecordCapabilitiesV1)
	fields := control.ProtoReflect().Descriptor().Fields()
	for i := 0; i < fields.Len(); i++ {
		field := fields.Get(i)
		if !field.IsList() {
			continue
		}
		list := permuted.ProtoReflect().Mutable(field).List()
		for a, b := 0, list.Len()-1; a < b; a, b = a+1, b-1 {
			x, y := list.Get(a), list.Get(b)
			list.Set(a, y)
			list.Set(b, x)
		}
	}
	check("permuted", permuted, nil)
	for i := 0; i < fields.Len(); i++ {
		field := fields.Get(i)
		name := string(field.Name())
		changed := proto.Clone(control).(*edgev1.EdgeRecordCapabilitiesV1)
		m := changed.ProtoReflect()
		switch {
		case field.IsList():
			list := m.Mutable(field).List()
			list.Append(list.Get(0))
			check("duplicate_"+name, changed, ErrCapabilityDuplicate)
			if err := CompareHelloCapabilities(changed, changed); !errors.Is(err, ErrCapabilityDuplicate) {
				t.Fatalf("identical duplicates accepted: %s", name)
			}
			list.Truncate(0)
		case field.Kind() == protoreflect.BytesKind:
			m.Set(field, protoreflect.ValueOfBytes(bytes.Repeat([]byte{0x32}, 32)))
		default:
			m.Set(field, protoreflect.ValueOfUint64(m.Get(field).Uint()+1))
		}
		check("different_"+name, changed, ErrCapabilityConflict)
	}
	goldenBytesLocal(t, "hello_capabilities_corpus.txt", []byte(manifest))
	// Both existing RPC carriers retain their legacy fields and the SAME typed value.
	for name, msg := range map[string]proto.Message{
		"agent":          &monitoring.AgentHelloRequest{Capabilities: []string{"icmp"}, EdgeRecordCapabilities: control},
		"control_stream": &monitoring.ControlStreamHello{Capabilities: []string{"icmp"}, EdgeRecordCapabilities: control},
	} {
		raw, err := proto.Marshal(msg)
		if err != nil {
			t.Fatal(err)
		}
		goldenBytesLocal(t, "hello_"+name+".bin", raw)
	}
}

func TestHelloCapabilitiesPresence(t *testing.T) {
	if err := CompareHelloCapabilities(nil, nil); err != nil {
		t.Fatal(err)
	}
	for _, pair := range [][2]*edgev1.EdgeRecordCapabilitiesV1{{nil, {}}, {{}, nil}} {
		if err := CompareHelloCapabilities(pair[0], pair[1]); !errors.Is(err, ErrCapabilityConflict) {
			t.Fatalf("presence: %v", err)
		}
	}
}

func TestHelloCapabilitiesCommittedCorpus(t *testing.T) {
	manifest, err := os.ReadFile(goldenPath("hello_capabilities_corpus.txt"))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(goldenPath("hello_capabilities_control.bin"))
	if err != nil {
		t.Fatal(err)
	}
	base := new(edgev1.EdgeRecordCapabilitiesV1)
	if err := proto.Unmarshal(raw, base); err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(manifest)), "\n") {
		row := strings.Fields(line)
		if len(row) != 2 {
			t.Fatalf("bad row: %q", line)
		}
		raw, err := os.ReadFile(goldenPath(row[0]))
		if err != nil {
			t.Fatal(err)
		}
		peer := new(edgev1.EdgeRecordCapabilitiesV1)
		if err := proto.Unmarshal(raw, peer); err != nil {
			t.Fatal(err)
		}
		wants := map[string]error{"equal": nil, "duplicate": ErrCapabilityDuplicate, "conflict": ErrCapabilityConflict}
		want, ok := wants[row[1]]
		if !ok {
			t.Fatalf("bad verdict: %q", row[1])
		}
		if err := CompareHelloCapabilities(base, peer); !errors.Is(err, want) {
			t.Fatalf("%s: %v", row[0], err)
		}
	}
}
