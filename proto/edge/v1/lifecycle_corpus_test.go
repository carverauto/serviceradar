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
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func TestLifecycleStructuralCorpus(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "version_mtr_completion_ok.bin"))
	if err != nil {
		t.Fatal(err)
	}
	control := &edgev1.SweepExecutionEventV1{}
	if err := proto.Unmarshal(raw, control); err != nil {
		t.Fatal(err)
	}
	var manifest strings.Builder
	emit := func(name string, accepted bool, event *edgev1.SweepExecutionEventV1) {
		t.Helper()
		raw := golden(t, "lifecycle_structural_"+name+".bin", event)
		decoded := &edgev1.SweepExecutionEventV1{}
		if err := proto.Unmarshal(raw, decoded); err != nil {
			t.Fatal(err)
		}
		err := edgerecord.ValidateSweepExecutionEvent(decoded)
		if (err == nil) != accepted {
			t.Fatalf("%s accepted=%v got %v", name, accepted, err)
		}
		fmt.Fprintf(&manifest, "lifecycle_structural_%s.bin %t\n", name, accepted)
	}
	emit("completed", true, control)
	for _, tc := range []struct {
		name   string
		change func(*edgev1.SweepExecutionEventV1)
	}{
		{"execution_id", func(e *edgev1.SweepExecutionEventV1) { e.ExecutionId = nil }},
		{"plan_id", func(e *edgev1.SweepExecutionEventV1) { e.ExecutionPlanId = nil }},
		{"range_id", func(e *edgev1.SweepExecutionEventV1) { e.TargetRangeId = nil }},
		{"plan_digest", func(e *edgev1.SweepExecutionEventV1) { e.ExecutionPlanSha256 = nil }},
		{"time_zero", func(e *edgev1.SweepExecutionEventV1) { e.EmittedAtUnixNano = 0 }},
		{"time_negative", func(e *edgev1.SweepExecutionEventV1) { e.EmittedAtUnixNano = -1 }},
		{"kind_zero", func(e *edgev1.SweepExecutionEventV1) { e.Kind = 0 }},
		{"kind_negative", func(e *edgev1.SweepExecutionEventV1) { e.Kind = -1 }},
		{"kind_unknown", func(e *edgev1.SweepExecutionEventV1) { e.Kind = 99 }},
		{"durable_over", func(e *edgev1.SweepExecutionEventV1) { e.DurableThroughBatchSequence = e.TerminalBatchSequence + 1 }},
		{"summaries_over", func(e *edgev1.SweepExecutionEventV1) { e.EmittedMtrSummaries = e.ExpectedMtrSummaries + 1 }},
		{"traces_over", func(e *edgev1.SweepExecutionEventV1) { e.EmittedMtrTraces = e.ExpectedMtrTraces + 1 }},
		{"completion_digest", func(e *edgev1.SweepExecutionEventV1) { e.MtrCompletionDigest = nil }},
		{"plan_root", func(e *edgev1.SweepExecutionEventV1) { e.PlanRootSha256 = nil }},
		{"nonterminal_proof", func(e *edgev1.SweepExecutionEventV1) {
			e.Kind = edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_START
		}},
		{"retired_tag", func(e *edgev1.SweepExecutionEventV1) { e.ProtoReflect().SetUnknown([]byte{162, 1, 1, 0}) }},
	} {
		event := proto.Clone(control).(*edgev1.SweepExecutionEventV1)
		tc.change(event)
		emit(tc.name, false, event)
	}
	// Equality is legal in each completed-event counter relation.
	event := proto.Clone(control).(*edgev1.SweepExecutionEventV1)
	event.DurableThroughBatchSequence = event.TerminalBatchSequence
	event.ExpectedMtrSummaries = 3
	event.EmittedMtrSummaries = 3
	event.ExpectedMtrTraces = 4
	event.EmittedMtrTraces = 4
	emit("counter_equality", true, event)
	for _, n := range []int{0, 1, 256, 257} {
		event := proto.Clone(control).(*edgev1.SweepExecutionEventV1)
		event.Kind = edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_ABORTED
		event.MtrCompletionDigest = nil
		event.AbortReason = strings.Repeat("x", n)
		emit(fmt.Sprintf("abort_%d", n), n == 1 || n == 256, event)
	}
	for _, n := range []int{0, 1} {
		event := proto.Clone(control).(*edgev1.SweepExecutionEventV1)
		event.Kind = edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_START
		event.MtrCompletionDigest = nil
		event.AbortReason = strings.Repeat("x", n)
		emit(fmt.Sprintf("start_reason_%d", n), n == 0, event)
	}
	goldenText(t, "lifecycle_corpus.txt", manifest.String())
}
