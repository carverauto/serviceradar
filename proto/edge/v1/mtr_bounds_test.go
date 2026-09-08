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

package edgev1_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// These are decoded-body limits, not raw wire ceilings. Task 1.4 owns the
// Go boundary; there is no Elixir MTR body validator to claim as a peer.
func TestMtrSemanticBounds(t *testing.T) {
	r := canonicalMtrRecord(t, edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1)
	var control edgev1.MtrTraceBatchV1
	if err := proto.Unmarshal(r.GetPayload(), &control); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		field string
		limit int
		want  error
	}{
		{"traces", 128, edgerecord.ErrMtrBounds},
		{"hops", 256, edgerecord.ErrMtrBounds},
		{"ecmp", 16, edgerecord.ErrMtrHop},
		{"mpls", 16, edgerecord.ErrMtrHop},
		{"target", 256, edgerecord.ErrMtrTrace},
		{"error", 256, edgerecord.ErrMtrTrace},
		{"hostname", 256, edgerecord.ErrMtrHop},
		{"asn_org", 256, edgerecord.ErrMtrHop},
	} {
		t.Run(tc.field, func(t *testing.T) {
			for _, n := range []int{tc.limit, tc.limit + 1} {
				batch := proto.Clone(&control).(*edgev1.MtrTraceBatchV1)
				tr := batch.Traces[0]
				hop := tr.Hops[0]
				switch tc.field {
				case "traces":
					for len(batch.Traces) < n {
						batch.Traces = append(batch.Traces, proto.Clone(tr).(*edgev1.MtrTraceEventV1))
					}
				case "hops":
					tr.TotalHops = uint32(n)
					for len(tr.Hops) < n {
						next := proto.Clone(hop).(*edgev1.MtrTraceHopV1)
						next.HopNumber = uint32(len(tr.Hops) + 1)
						tr.Hops = append(tr.Hops, next)
					}
				case "ecmp":
					for len(hop.EcmpAddresses) < n {
						hop.EcmpAddresses = append(hop.EcmpAddresses, []byte{192, 0, 2, byte(len(hop.EcmpAddresses) + 1)})
					}
				case "mpls":
					for len(hop.MplsLabels) < n {
						hop.MplsLabels = append(hop.MplsLabels, &edgev1.MtrMplsLabelV1{})
					}
				case "target":
					tr.Target = strings.Repeat("x", n)
				case "error":
					tr.ErrorCode = strings.Repeat("x", n)
				case "hostname":
					hop.Hostname = strings.Repeat("x", n)
				case "asn_org":
					hop.AsnOrg = strings.Repeat("x", n)
				}
				// Exercise a decoded wire value and make sure the byte ceiling
				// cannot hide the individual semantic predicate under test.
				raw := mustMarshal(batch)
				if len(raw) >= 262144 {
					t.Fatal("semantic vector unexpectedly reaches batch byte ceiling")
				}
				var decoded edgev1.MtrTraceBatchV1
				if err := proto.Unmarshal(raw, &decoded); err != nil {
					t.Fatal(err)
				}
				err := edgerecord.ValidateMtrTraceBatch(&decoded)
				if n == tc.limit && err != nil {
					t.Fatalf("at %d: %v", n, err)
				}
				if n > tc.limit && !errors.Is(err, tc.want) {
					t.Fatalf("over %d: got %v, want %v", n, err, tc.want)
				}
			}
		})
	}
}

func TestMtrCanonicalBatchByteBound(t *testing.T) {
	r := canonicalMtrRecord(t, edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1)
	var batch edgev1.MtrTraceBatchV1
	if err := proto.Unmarshal(r.GetPayload(), &batch); err != nil {
		t.Fatal(err)
	}
	tr := batch.Traces[0]
	tr.TotalHops = 256
	tr.Hops = nil
	for i := 1; i <= 256; i++ {
		tr.Hops = append(tr.Hops, &edgev1.MtrTraceHopV1{
			HopNumber: uint32(i), Hostname: strings.Repeat("h", 256), AsnOrg: strings.Repeat("a", 256),
		})
	}
	batch.Traces = append(batch.Traces, proto.Clone(tr).(*edgev1.MtrTraceEventV1))
	// All fields remain within their semantic bounds. Trim whole optional strings
	// until the body is below the frozen canonical byte ceiling, then fill the gap.
	for _, hop := range tr.Hops {
		if proto.Size(&batch) <= 262144 {
			break
		}
		hop.AsnOrg = ""
	}
	for _, size := range []int{262144, 262145} {
		found := false
		// Two target lengths cover a possible protobuf varint-length transition.
		for targetLen := 1; targetLen <= 2 && !found; targetLen++ {
			tr.Target = strings.Repeat("x", targetLen)
			for padding := 0; padding <= 256; padding++ {
				tr.ErrorCode = strings.Repeat("e", padding)
				if proto.Size(&batch) == size {
					found = true
					break
				}
			}
		}
		if !found {
			t.Fatalf("could not construct canonical body of %d bytes", size)
		}
		raw := mustMarshal(&batch)
		if len(raw) != size {
			t.Fatalf("canonical bytes: got %d, want %d", len(raw), size)
		}
		var decoded edgev1.MtrTraceBatchV1
		if err := proto.Unmarshal(raw, &decoded); err != nil {
			t.Fatal(err)
		}
		err := edgerecord.ValidateMtrTraceBatch(&decoded)
		if size == 262144 && err != nil {
			t.Fatalf("at ceiling: %v", err)
		}
		if size == 262145 && !errors.Is(err, edgerecord.ErrMtrBounds) {
			t.Fatalf("over ceiling: got %v, want ErrMtrBounds", err)
		}
	}
}
