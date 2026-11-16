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

package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
)

// seedDrainedFlatSpool writes the layout a pre-lane agent's sender leaves after
// draining and reclaiming its spool (pointer symlink 32-byte target name,
// spool_id 16, checkpoint 88, resolved 8, empty data segment = 144 bytes).
func seedDrainedFlatSpool(t *testing.T, dir string) {
	t.Helper()
	data := ".spool-data-00000000000000000007"
	for _, step := range []error{
		os.MkdirAll(filepath.Join(dir, data), 0o700),
		os.WriteFile(filepath.Join(dir, data, "lane.seg"), nil, 0o600),
		os.WriteFile(filepath.Join(dir, data+".checkpoint"), make([]byte, 88), 0o600),
		os.Symlink(data, filepath.Join(dir, "lane.seg")),
		os.WriteFile(filepath.Join(dir, "resolved"), make([]byte, 8), 0o600),
		os.WriteFile(filepath.Join(dir, "spool_id"), make([]byte, 16), 0o600),
	} {
		if step != nil {
			t.Fatal(step)
		}
	}
}

// An upgraded agent whose spool dir holds only a drained pre-lane flat spool
// retires it at start: the hello reports no retained legacy bytes (so core
// raises no unsupported_legacy_storage condition), the log carries the audit
// line, and the flat entries are gone.
func TestRunningAgentRetiresDrainedFlatSpool(t *testing.T) {
	gw, addr := listenSpoolHelloGateway(t, false, 0)
	dir := filepath.Join(t.TempDir(), "spool")
	seedDrainedFlatSpool(t, dir)
	logs, _ := runSpoolAgent(t, addr, fmt.Sprintf(`{"spool_dir": %q, "poll_interval": "1h"}`, dir))

	hello := waitForHello(t, gw, logs)
	status := hello.GetEdgeRecordSpool()
	if status == nil || !status.GetAvailable() || status.GetRetainedLegacyBytes() != 0 {
		t.Fatalf("hello edge_record_spool = %v, want available with retained_legacy_bytes=0\nlog:\n%s", status, logs.snapshot())
	}
	waitForLog(t, logs, "Retired drained legacy edge storage", 20*time.Second)
	for _, name := range []string{"lane.seg", "resolved", "spool_id", ".spool-data-00000000000000000007", ".spool-data-00000000000000000007.checkpoint"} {
		if _, err := os.Lstat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Fatalf("flat entry %s still present: %v", name, err)
		}
	}
	t.Logf("hello retained_legacy_bytes=%d available=%v", status.GetRetainedLegacyBytes(), status.GetAvailable())
}

// A flat spool still holding a committed, undelivered record is never removed
// while it cannot be handed off: with no trust snapshot installed, the running
// agent keeps it byte-identical, reports its bytes in the hello, logs that it is
// handing the tail off, and reports the handoff as pending rather than retiring.
func TestRunningAgentRetainsFlatSpoolWithUndeliveredRecord(t *testing.T) {
	gw, addr := listenSpoolHelloGateway(t, false, 0)
	dir := filepath.Join(t.TempDir(), "spool")
	flat, err := spool.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := flat.Append(make([]byte, 16), []byte("synthetic undelivered record")); err != nil {
		t.Fatal(err)
	}
	if err := flat.Close(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(filepath.Join(dir, "lane.seg"))
	if err != nil {
		t.Fatal(err)
	}
	logs, _ := runSpoolAgent(t, addr, fmt.Sprintf(`{"spool_dir": %q, "poll_interval": "1h"}`, dir))

	hello := waitForHello(t, gw, logs)
	status := hello.GetEdgeRecordSpool()
	if status == nil || status.GetRetainedLegacyBytes() == 0 {
		t.Fatalf("hello edge_record_spool = %v, want retained_legacy_bytes > 0\nlog:\n%s", status, logs.snapshot())
	}
	waitForLog(t, logs, "Legacy edge storage holds undelivered records; handing them off to late admission", 20*time.Second)
	waitForLog(t, logs, "Legacy edge storage handoff pending; will retry", 20*time.Second)
	if bytes.Contains(logs.snapshot(), []byte("Retired drained legacy edge storage")) {
		t.Fatalf("agent claimed retirement of a spool holding a record\nlog:\n%s", logs.snapshot())
	}
	after, err := os.ReadFile(filepath.Join(dir, "lane.seg"))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("flat segment changed: %v", err)
	}
	t.Logf("hello retained_legacy_bytes=%d", status.GetRetainedLegacyBytes())
}
