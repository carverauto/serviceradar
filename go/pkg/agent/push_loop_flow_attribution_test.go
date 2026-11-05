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

package agent

import (
	"testing"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

func sampleFlowAttributionEvents(n int) []*netprobepb.FlowAttributionEvent {
	out := make([]*netprobepb.FlowAttributionEvent, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, &netprobepb.FlowAttributionEvent{
			Pid:             uint32(1000 + i),
			Comm:            "test-proc",
			RedactedCmdline: []string{"test-proc", "--arg"},
		})
	}
	return out
}

func TestFlowAttributionDeliveryQueueAcknowledgesOnlyDeliveredPrefix(t *testing.T) {
	var queue flowAttributionDeliveryQueue
	loads := 0

	load := func() *flowAttributionPendingBatch {
		loads++

		return &flowAttributionPendingBatch{
			events:              sampleFlowAttributionEvents(3),
			cumulativeDropped:   31,
			dropped:             9,
			dropBaselinePending: true,
		}
	}

	first := queue.getOrLoad(load)
	retry := queue.getOrLoad(load)

	if first == nil {
		t.Fatal("first pending batch is nil")
		return
	}
	if retry != first {
		t.Fatal("unacknowledged delivery loaded a different batch")
	}
	if got, want := loads, 1; got != want {
		t.Fatalf("loader calls before acknowledgement = %d, want %d", got, want)
	}

	cumulative, commitDrop, remaining, ok := queue.acknowledgePrefix(first, 1)
	if !ok {
		t.Fatal("acknowledgePrefix(first, 1) = false, want true")
	}
	if got, want := cumulative, uint64(31); got != want {
		t.Errorf("first acknowledged cumulative drop count = %d, want %d", got, want)
	}
	if !commitDrop {
		t.Error("first prefix acknowledgement did not commit drop baseline")
	}
	if got, want := remaining, 2; got != want {
		t.Errorf("remaining after first prefix = %d, want %d", got, want)
	}
	if got, want := first.events[0].GetPid(), uint32(1001); got != want {
		t.Errorf("first retained PID = %d, want %d", got, want)
	}
	if first.dropBaselinePending || first.dropped != 0 {
		t.Fatalf("drop baseline still pending after positive prefix acknowledgement: %+v", first)
	}

	cumulative, commitDrop, remaining, ok = queue.acknowledgePrefix(first, 1)
	if !ok {
		t.Fatal("second acknowledgePrefix(first, 1) = false, want true")
	}
	if cumulative != 0 || commitDrop {
		t.Errorf("second prefix repeated drop baseline: cumulative=%d commit=%t", cumulative, commitDrop)
	}
	if got, want := remaining, 1; got != want {
		t.Errorf("remaining after second prefix = %d, want %d", got, want)
	}

	if _, _, remaining, ok = queue.acknowledgePrefix(first, 1); !ok || remaining != 0 {
		t.Fatalf("final prefix acknowledgement = (remaining=%d, ok=%t), want (0, true)", remaining, ok)
	}

	next := queue.getOrLoad(load)
	if next == first {
		t.Fatal("acknowledged batch was reused")
	}
	if got, want := loads, 2; got != want {
		t.Fatalf("loader calls after acknowledgement = %d, want %d", got, want)
	}
	if _, _, _, ok := queue.acknowledgePrefix(first, 1); ok {
		t.Fatal("stale acknowledgement cleared the next batch")
	}
	if retry := queue.getOrLoad(load); retry != next {
		t.Fatal("stale acknowledgement replaced the current pending batch")
	}
}

func TestFlowAttributionDroppedSinceLast_TrackingDelta(t *testing.T) {
	var queue flowAttributionDeliveryQueue

	for _, step := range []struct {
		name       string
		cumulative uint64
		want       uint32
	}{
		// The sidecar's cumulative counter has advanced from 0 to 10 —
		// the entire delta is reported.
		{name: "first", cumulative: 10, want: 10},
		{name: "second", cumulative: 25, want: 15},
		{name: "unchanged", cumulative: 25, want: 0},
		// Counter wrap / reset (cumulative goes backwards): clamp to the
		// current cumulative and continue.
		{name: "wrap", cumulative: 3, want: 3},
	} {
		if got := queue.observeDropped(step.cumulative); got != step.want {
			t.Errorf("%s delta = %d, want %d", step.name, got, step.want)
		}
		queue.commitDropped(step.cumulative)
	}
}
