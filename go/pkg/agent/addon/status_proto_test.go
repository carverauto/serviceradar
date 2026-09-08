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

package addon

import (
	"testing"
	"time"
)

func TestToProtoStatusesMapsFields(t *testing.T) {
	statuses := []Status{
		{
			ID:           "bumblebee",
			State:        StateRunning,
			PID:          42,
			Version:      "0.2.0",
			Arch:         "arm64",
			RestartCount: 1,
			LastHealthAt: time.Unix(1_700_000_000, 0).UTC(),
		},
		{
			ID:                "netprobe",
			State:             StateUnhealthy,
			DegradationReason: "CAP_BPF not granted",
		},
		{
			ID:               "anomaly",
			State:            StateRunning,
			ResourceLimitErr: "resource limits not enforced: no delegated cgroup",
		},
		{
			ID:        "edge-anomaly",
			State:     StateCircuitOpen,
			LastError: "restart circuit open: addon exited",
		},
	}

	out := ToProtoStatuses(statuses)
	if len(out) != 4 {
		t.Fatalf("expected 4 proto statuses, got %d", len(out))
	}

	if out[0].GetName() != "addon:bumblebee" {
		t.Fatalf("expected name addon:bumblebee, got %q", out[0].GetName())
	}
	if out[0].GetState() != string(StateRunning) {
		t.Fatalf("expected state running, got %q", out[0].GetState())
	}
	if out[0].GetPid() != 42 {
		t.Fatalf("expected pid 42, got %d", out[0].GetPid())
	}
	if out[0].GetRestartCount() != 1 {
		t.Fatalf("expected restart_count 1, got %d", out[0].GetRestartCount())
	}
	if out[0].GetLastHealthAt() == 0 {
		t.Fatalf("expected last_health_at to be set")
	}
	if out[0].GetVersion() != "0.2.0" {
		t.Fatalf("expected version 0.2.0, got %q", out[0].GetVersion())
	}
	if out[0].GetArch() != "arm64" {
		t.Fatalf("expected arch arm64, got %q", out[0].GetArch())
	}

	// Degradation reason is surfaced through last_error when no other error.
	if out[1].GetLastError() != "CAP_BPF not granted" {
		t.Fatalf("expected degradation reason via last_error, got %q", out[1].GetLastError())
	}
	if out[2].GetLastError() != "resource limits not enforced: no delegated cgroup" {
		t.Fatalf("expected resource limit error via last_error, got %q", out[2].GetLastError())
	}
	if out[3].GetState() != string(StateCircuitOpen) {
		t.Fatalf("expected circuit_open state, got %q", out[3].GetState())
	}
	if out[3].GetLastError() != "restart circuit open: addon exited" {
		t.Fatalf("expected circuit-open last_error, got %q", out[3].GetLastError())
	}
}

func TestToProtoStatusesEmpty(t *testing.T) {
	if ToProtoStatuses(nil) != nil {
		t.Fatalf("expected nil for empty input")
	}
}
