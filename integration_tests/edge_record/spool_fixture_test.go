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

package verticalslice

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// Offline fixture access shares the production facade, but never a live writer.
// Restart appends logs so outage probes retain their original byte offsets.
func (h *harness) withAgentStorage(t *testing.T, visit func(*agent.RecordSpool)) {
	t.Helper()
	h.agent.Stop()
	defer func() {
		if err := h.agent.Restart(); err != nil {
			t.Errorf("restart agent after offline storage access: %v", err)
		}
	}()
	storage, err := openFixtureStorage(h.agent.SpoolDir)
	if err != nil {
		t.Fatalf("open agent storage: %v", err)
	}
	defer func() {
		if err := storage.Close(); err != nil {
			t.Errorf("close agent storage: %v", err)
		}
	}()
	visit(storage)
}

func openFixtureStorage(dir string) (*agent.RecordSpool, error) {
	allocator, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: 1 << 30, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: spool.DefaultRecoveryFootprint()})
	if err != nil {
		return nil, err
	}
	return agent.OpenRecordSpool(dir, allocator)
}

func appendFixtureStorage(storage *agent.RecordSpool, body []byte, trust *edgerecord.TrustSnapshot) (spool.Receipt, error) {
	storage.SetTrustProvider(func() *edgerecord.TrustSnapshot { return trust })
	prepared, err := storage.PrepareRecord(body)
	if err != nil {
		return spool.Receipt{}, err
	}
	return storage.AppendPrepared("vertical-slice-fixture", prepared)
}

func (h *harness) appendAgentSpool(t *testing.T, fixture *FixtureRecord) spool.Receipt {
	t.Helper()
	// Fetch the actual persisted authority/fences from the isolated core release.
	// The fixture's partition UUID is also its network scope UUID.
	expr := fmt.Sprintf(`
 scope = Base.decode64!(%q) |> Ecto.UUID.load!()
 {:ok, trust} = ServiceRadar.Edge.RecordTrust.agent_snapshot(%q, scope)
 IO.puts("FIXTURE_TRUST:" <> Base.encode64(Jason.encode!(trust)))
 `, base64.StdEncoding.EncodeToString(fixture.NetworkScopeID), h.certSet.AgentComponentID)
	out, err := h.coreProc.RPC(expr, rpcTimeout)
	if err != nil {
		t.Fatalf("read core fixture trust: %v", err)
	}
	var raw []byte
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "FIXTURE_TRUST:") {
			raw, err = base64.StdEncoding.DecodeString(strings.TrimPrefix(line, "FIXTURE_TRUST:"))
			break
		}
	}
	if err != nil || len(raw) == 0 {
		t.Fatalf("core returned no valid fixture trust: %v", err)
	}
	trust, err := edgerecord.ParseTrustDocument(raw, []byte(h.certSet.AgentComponentID), 1)
	if err != nil {
		t.Fatalf("parse core fixture trust: %v", err)
	}
	var receipt spool.Receipt
	h.withAgentStorage(t, func(storage *agent.RecordSpool) {
		receipt, err = appendFixtureStorage(storage, fixture.RecordBytes, trust)
		if err != nil {
			t.Fatalf("typed fixture append: %v", err)
		}
	})
	return receipt
}

type acceptedFixture struct {
	receipt spool.Receipt
	fixture *FixtureRecord
}

func fixtureSource(t *testing.T, storage *agent.RecordSpool, receipt spool.Receipt) agent.RecordSource {
	t.Helper()
	var cursor agent.RecordSpoolCursor
	for {
		source, ok := storage.NextSource(&cursor)
		if !ok {
			break
		}
		if bytes.Equal(source.Identity.SpoolID, receipt.Generation.SpoolID) {
			if !reflect.DeepEqual(source.Identity, receipt.Generation) {
				t.Fatalf("frozen generation identity changed: got %+v, want %+v", source.Identity, receipt.Generation)
			}
			return source.Source
		}
	}
	t.Fatalf("generation %x missing from production inventory", receipt.Generation.SpoolID)
	return nil
}

func (h *harness) requireSpoolEntryUnreclaimed(t *testing.T, receipt spool.Receipt, fixture *FixtureRecord) {
	t.Helper()
	h.withAgentStorage(t, func(storage *agent.RecordSpool) {
		source := fixtureSource(t, storage, receipt)
		if resolved := source.Resolved(); resolved >= receipt.Sequence {
			t.Errorf("generation %x resolved %d covers withheld sequence %d", receipt.Generation.SpoolID, resolved, receipt.Sequence)
		}
		found := false
		if err := source.ScanFrom(0, func(record spool.Record) bool {
			if record.Sequence == receipt.Sequence {
				found = true
				if !bytes.Equal(record.EventID, fixture.EventID) || !bytes.Equal(record.Body, fixture.RecordBytes) {
					t.Error("withheld slot does not contain the exact fixture bytes")
				}
			}
			return true
		}); err != nil {
			t.Fatalf("scan withheld generation: %v", err)
		}
		if !found {
			t.Errorf("withheld generation %x sequence %d is absent from sender read path", receipt.Generation.SpoolID, receipt.Sequence)
		}
	})
}

func requireAcceptedGenerations(t *testing.T, storage *agent.RecordSpool, accepted []acceptedFixture) {
	t.Helper()
	type slot struct {
		generation string
		sequence   uint64
	}
	known := make(map[slot]bool, len(accepted))
	for _, fixture := range accepted {
		known[slot{string(fixture.receipt.Generation.SpoolID), fixture.receipt.Sequence}] = true
		source := fixtureSource(t, storage, fixture.receipt)
		if source.Resolved() < fixture.receipt.Sequence {
			t.Errorf("generation %x sequence %d has no durable terminal resolution", fixture.receipt.Generation.SpoolID, fixture.receipt.Sequence)
		}
	}
	var cursor agent.RecordSpoolCursor
	for {
		generation, ok := storage.NextSource(&cursor)
		if !ok {
			break
		}
		highest := generation.Source.RestartResolution().HighWater
		for sequence := uint64(1); sequence <= highest; sequence++ {
			if !known[slot{string(generation.Identity.SpoolID), sequence}] {
				t.Fatalf("generation %x allocated unknown fixture sequence %d", generation.Identity.SpoolID, sequence)
			}
		}
		if err := generation.Source.ScanFrom(0, func(record spool.Record) bool {
			t.Errorf("accepted generation %x sequence %d remains on the sender read path", generation.Identity.SpoolID, record.Sequence)
			return true
		}); err != nil {
			t.Fatalf("scan accepted generation: %v", err)
		}
	}
}

// This owns harness fixture placement, not the spool's binding grammar: a fresh
// production facade must discover exactly what the offline helper appended.
func TestOfflineFixtureAppearsInAgentGenerationInventory(t *testing.T) {
	const principal = "vslice-offline-agent"
	fixture, err := BuildSweepFixture([]byte(principal))
	if err != nil {
		t.Fatal(err)
	}
	var record edgev1.EdgeRecordV1
	if err := proto.Unmarshal(fixture.RecordBytes, &record); err != nil {
		t.Fatal(err)
	}
	producer := record.GetProducerContext()
	raw, err := json.Marshal(map[string]any{
		"keys":   []any{map[string]any{"issuer_id": []byte(fixtureIssuerID), "issuer_key_id": fixtureIssuerKeyID(), "public_key": []byte(FixtureIssuerPublicKey()), "purposes": []string{"production", "source", "delivery"}, "status": "valid"}},
		"fences": []any{map[string]any{"network_scope_id": fixture.NetworkScopeID, "producer_assignment_id": producer.GetProducerAssignmentId(), "run_shard": producer.GetRunShard(), "authority_epoch": producer.GetAuthorityEpoch()}},
		"scopes": []any{map[string]any{"agent_id": principal, "network_scope_ids": [][]byte{fixture.NetworkScopeID}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	trust, err := edgerecord.ParseTrustDocument(raw, []byte(principal), 1)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	storage, err := openFixtureStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	var cursor agent.RecordSpoolCursor
	if _, exists := storage.NextSource(&cursor); exists {
		t.Fatal("fresh agent storage already contains a generation")
	}
	receipt, appendErr := appendFixtureStorage(storage, fixture.RecordBytes, trust)
	closeErr := storage.Close()
	if appendErr != nil {
		t.Fatal(appendErr)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}
	fresh, err := openFixtureStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	source := fixtureSource(t, fresh, receipt)
	var records []spool.Record
	if err := source.ScanFrom(0, func(record spool.Record) bool { records = append(records, record); return true }); err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].Sequence != receipt.Sequence || !bytes.Equal(records[0].EventID, fixture.EventID) || !bytes.Equal(records[0].Body, fixture.RecordBytes) {
		t.Fatalf("offline fixture absent or changed on sender path: %v", records)
	}
	if fresh.RetainedLegacyBytes() != 0 {
		t.Fatal("offline append wrote unsupported flat storage")
	}
}

// The fixture writer depends on Stop reaping the former process and Restart
// preserving log offsets. A small process exercises those OS boundaries without
// pretending to exercise the real agent/gateway protocol.
func TestAgentRestartReapsProcessAndPreservesLogs(t *testing.T) {
	dir := t.TempDir()
	binary := filepath.Join(dir, "agent-lifecycle")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\necho started\nexec sleep 60\n"), 0700); err != nil {
		t.Fatal(err)
	}
	process := &AgentProcess{binaryPath: binary, workDir: dir, stdoutPath: filepath.Join(dir, "stdout.log"), stderrPath: filepath.Join(dir, "stderr.log")}
	defer process.Stop()
	for starts := 1; starts <= 2; starts++ {
		if err := process.Restart(); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for {
			log, err := os.ReadFile(process.stdoutPath)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Count(string(log), "started\n") == starts {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("restart lost earlier output or process did not start: %q", log)
			}
			time.Sleep(10 * time.Millisecond)
		}
		command := process.cmd
		process.Stop()
		if command.ProcessState == nil {
			t.Fatal("Stop returned before reaping the agent")
		}
	}
}
