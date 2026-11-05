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

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

func TestAddonTelemetryBufferReportsDeltaAndTotalDrops(t *testing.T) {
	buffer := newAddonTelemetryBuffer(1)
	batch := &addonpb.TelemetryBatch{}

	buffer.enqueue("powerdns", batch)
	buffer.enqueue("powerdns", batch)
	buffer.enqueue("powerdns", batch)

	envelopes, droppedDelta, droppedTotal := buffer.drain(10)
	if len(envelopes) != 1 {
		t.Fatalf("drained envelopes = %d, want 1", len(envelopes))
	}
	if droppedDelta != 2 {
		t.Fatalf("dropped delta = %d, want 2", droppedDelta)
	}
	if droppedTotal != 2 {
		t.Fatalf("dropped total = %d, want 2", droppedTotal)
	}

	_, droppedDelta, droppedTotal = buffer.drain(10)
	if droppedDelta != 0 {
		t.Fatalf("second dropped delta = %d, want 0", droppedDelta)
	}
	if droppedTotal != 2 {
		t.Fatalf("second dropped total = %d, want 2", droppedTotal)
	}
}
