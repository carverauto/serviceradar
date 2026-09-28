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
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/projection"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func TestProjectionRowsSharedBatchCorpus(t *testing.T) {
	batch := canonicalSweepBatch()
	batch.Hosts[0].Address = []byte{192, 0, 2, 1}
	batch.TestedChecks = append(batch.TestedChecks,
		&edgev1.SweepTestV1{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_SYN, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 443},
		&edgev1.SweepTestV1{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_SYN, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 80})
	batch.ConfiguredModeBits |= uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN)
	host := batch.Hosts[0]
	host.ResultModeBits = batch.ConfiguredModeBits
	host.Tcp = &edgev1.SweepTcpSummaryV1{Outcome: edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS, TestedCount: 2, OpenCount: 1}
	host.OpenPorts = []*edgev1.SweepOpenPortV1{{TestedCheckIndex: 2}}
	host.PortErrors = []*edgev1.SweepPortErrorV1{{TestedCheckIndex: 3, ErrorCode: "refused"}}
	batch.Hosts = append(batch.Hosts, &edgev1.SweepHostObservationV1{
		Address: []byte{192, 0, 2, 2}, ResultModeBits: uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP),
		Icmp: proto.Clone(host.Icmp).(*edgev1.SweepIcmpSummaryV1), ModeRevision: 1,
	})
	golden(t, "projection_sweep_batch.bin", batch)
	batch.Hosts = nil
	golden(t, "projection_empty_sweep_batch.bin", batch)

	// Bare positive batch artifacts use this suffix. Record-wrapped and invalid
	// field corpora are intentionally not decoded as arbitrary protobuf types.
	families := map[string]string{
		"sweep_batch.bin": "sweep", "mtr_batch.bin": "mtr",
		"projection_sweep_batch.bin": "sweep", "projection_empty_sweep_batch.bin": "sweep",
	}
	paths, err := filepath.Glob("testdata/*batch.bin")
	if err != nil || len(paths) != len(families) {
		t.Fatalf("bare batch fixture inventory: %v, %v", paths, err)
	}
	sort.Strings(paths)
	var manifest strings.Builder
	for _, path := range paths {
		name := filepath.Base(path)
		family, known := families[name]
		if !known {
			t.Fatalf("unclassified batch fixture %s", name)
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var rows []projection.Row
		var count int
		if family == "sweep" {
			var b edgev1.SweepObservationBatchV1
			if err := proto.Unmarshal(raw, &b); err != nil {
				t.Fatal(err)
			}
			if err := edgerecord.ValidateSweepObservationBatch(&b); err != nil {
				t.Fatalf("%s is not a valid batch: %v", name, err)
			}
			rows, count = projection.SweepProjectionRows(&b), projection.SweepRows(&b)
		} else {
			var b edgev1.MtrTraceBatchV1
			if err := proto.Unmarshal(raw, &b); err != nil {
				t.Fatal(err)
			}
			if err := edgerecord.ValidateMtrTraceBatch(&b); err != nil {
				t.Fatalf("%s is not a valid batch: %v", name, err)
			}
			rows, count = projection.MtrProjectionRows(&b), projection.MtrRows(&b)
		}
		if len(rows) != count {
			t.Fatalf("%s: %d enumerated rows, count %d", name, len(rows), count)
		}
		encoded := make([]string, len(rows))
		for i, row := range rows {
			encoded[i] = fmt.Sprintf("%s:%d:%d", row.Kind, row.BatchIndex, row.ElementIndex)
		}
		rowText := strings.Join(encoded, ",")
		if len(rows) == 0 {
			rowText = "-"
		}
		fmt.Fprintf(&manifest, "%s %s %d %s\n", name, family, count, rowText)
	}
	goldenText(t, "projection_rows_corpus.txt", manifest.String())
}
