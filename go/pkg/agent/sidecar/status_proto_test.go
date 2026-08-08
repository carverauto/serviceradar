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

package sidecar_test

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
)

func TestToProtoStatuses(t *testing.T) {
	lastHealth := time.Unix(1_800_000_000, 123).UTC()

	got := sidecar.ToProtoStatuses([]sidecar.Status{{
		Name:         "netprobe",
		State:        sidecar.StateRunning,
		PID:          1234,
		LastHealthAt: lastHealth,
		RestartCount: 2,
		LastError:    "last error",
	}})
	if len(got) != 1 {
		t.Fatalf("len(ToProtoStatuses()) = %d, want 1", len(got))
	}

	status := got[0]
	if status.GetName() != "netprobe" {
		t.Fatalf("Name = %q, want netprobe", status.GetName())
	}
	if status.GetState() != string(sidecar.StateRunning) {
		t.Fatalf("State = %q, want %q", status.GetState(), sidecar.StateRunning)
	}
	if status.GetPid() != 1234 {
		t.Fatalf("Pid = %d, want 1234", status.GetPid())
	}
	if status.GetLastHealthAt() != lastHealth.UnixNano() {
		t.Fatalf("LastHealthAt = %d, want %d", status.GetLastHealthAt(), lastHealth.UnixNano())
	}
	if status.GetRestartCount() != 2 {
		t.Fatalf("RestartCount = %d, want 2", status.GetRestartCount())
	}
	if status.GetLastError() != "last error" {
		t.Fatalf("LastError = %q, want last error", status.GetLastError())
	}
}

func TestToProtoStatusesCapsRestartCount(t *testing.T) {
	got := sidecar.ToProtoStatuses([]sidecar.Status{{
		Name:         "netprobe",
		RestartCount: int(^uint32(0)) + 1,
	}})

	if got[0].GetRestartCount() != ^uint32(0) {
		t.Fatalf("RestartCount = %d, want max uint32", got[0].GetRestartCount())
	}
}
