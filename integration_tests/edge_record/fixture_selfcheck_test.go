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
	"crypto/sha256"
	"testing"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// TestBuildSweepFixtureIsValidAndDecodable proves BuildSweepFixture's output
// actually decodes and validates through the same Go-side checks the real
// production path applies, before the vertical slice test relies on it.
func TestBuildSweepFixtureIsValidAndDecodable(t *testing.T) {
	fx, err := BuildSweepFixture([]byte("vslice-agent-01"))
	if err != nil {
		t.Fatalf("BuildSweepFixture: %v", err)
	}

	if err := edgerecord.ValidateUUIDv7(fx.EventID); err != nil {
		t.Fatalf("event id not a valid UUIDv7: %v", err)
	}
	if len(fx.NetworkScopeID) != 16 {
		t.Fatalf("network scope id must be 16 bytes (uuid column), got %d", len(fx.NetworkScopeID))
	}
	if len(fx.SemanticEnvelopeSHA256) != 32 {
		t.Fatalf("semantic envelope digest must be 32 bytes, got %d", len(fx.SemanticEnvelopeSHA256))
	}

	sum := sha256.Sum256(fx.RecordBytes)
	if !bytes.Equal(sum[:], fx.RecordSHA256) {
		t.Fatalf("RecordSHA256 does not match sha256(RecordBytes)")
	}

	var record edgev1.EdgeRecordV1
	if err := proto.Unmarshal(fx.RecordBytes, &record); err != nil {
		t.Fatalf("record bytes must decode as EdgeRecordV1: %v", err)
	}
	if err := edgerecord.ValidateRecord(&record); err != nil {
		t.Fatalf("decoded record must pass ValidateRecord: %v", err)
	}
	if !bytes.Equal(record.GetEventId(), fx.EventID) {
		t.Fatalf("decoded event id mismatch")
	}
	if !bytes.Equal(record.GetNetworkScopeId(), fx.NetworkScopeID) {
		t.Fatalf("decoded network scope id mismatch")
	}

	var batch edgev1.SweepObservationBatchV1
	if err := proto.Unmarshal(record.GetPayload(), &batch); err != nil {
		t.Fatalf("payload must decode as SweepObservationBatchV1: %v", err)
	}
	if err := edgerecord.ValidateSweepObservationBatch(&batch); err != nil {
		t.Fatalf("decoded sweep batch must pass ValidateSweepObservationBatch: %v", err)
	}
	if got, want := len(batch.GetHosts()), 3; got != want {
		t.Fatalf("host count = %d, want %d", got, want)
	}
	if fx.ProjectedRowCount != 6 {
		t.Fatalf("ProjectedRowCount = %d, want 6 (1 reachability + 3 reachability+open_port+port_error + 2 reachability+mtr)", fx.ProjectedRowCount)
	}
	if len(fx.RowKeys) != fx.ProjectedRowCount {
		t.Fatalf("len(RowKeys) = %d, want %d", len(fx.RowKeys), fx.ProjectedRowCount)
	}
	for i, k := range fx.RowKeys {
		if len(k) != 32 {
			t.Fatalf("row key %d must be 32 bytes, got %d", i, len(k))
		}
	}

	// Frame-level check: the delivery frame the sender builds around this
	// record must also pass local validation, matching go/pkg/edge/sender's
	// own buildFrame + ValidateDeliveryFrame call.
	spoolID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("spool id: %v", err)
	}
	frame := &edgev1.EdgeDeliveryFrameV1{
		SpoolId:      spoolID,
		Sequence:     1,
		RecordSha256: fx.RecordSHA256,
		RecordBytes:  fx.RecordBytes,
	}
	if err := edgerecord.ValidateDeliveryFrame(frame, true); err != nil {
		t.Fatalf("built frame failed ValidateDeliveryFrame: %v", err)
	}
}

// TestBuildConflictingSweepFixtureSharesScopeButDiffersInContent proves the
// group-C conflict fixture reuses the primary fixture's NetworkScopeID while
// differing in every content-derived field, as task 0.12 Group C requires.
func TestBuildConflictingSweepFixtureSharesScopeButDiffersInContent(t *testing.T) {
	primary, err := BuildSweepFixture([]byte("vslice-agent-01"))
	if err != nil {
		t.Fatalf("BuildSweepFixture: %v", err)
	}
	conflict, err := BuildConflictingSweepFixture(primary.NetworkScopeID, []byte("vslice-agent-01"))
	if err != nil {
		t.Fatalf("BuildConflictingSweepFixture: %v", err)
	}

	if !bytes.Equal(primary.NetworkScopeID, conflict.NetworkScopeID) {
		t.Fatalf("conflicting fixture must share the primary fixture's network scope id")
	}
	if bytes.Equal(primary.EventID, conflict.EventID) {
		t.Fatalf("conflicting fixture must have a distinct event id")
	}
	if bytes.Equal(primary.RecordSHA256, conflict.RecordSHA256) {
		t.Fatalf("conflicting fixture must have a distinct record_sha256")
	}
	if bytes.Equal(primary.SemanticEnvelopeSHA256, conflict.SemanticEnvelopeSHA256) {
		t.Fatalf("conflicting fixture must have a distinct semantic envelope digest")
	}

	var record edgev1.EdgeRecordV1
	if err := proto.Unmarshal(conflict.RecordBytes, &record); err != nil {
		t.Fatalf("conflicting record bytes must decode: %v", err)
	}
	if err := edgerecord.ValidateRecord(&record); err != nil {
		t.Fatalf("conflicting record must pass ValidateRecord: %v", err)
	}
	if !bytes.Equal(record.GetNetworkScopeId(), primary.NetworkScopeID) {
		t.Fatalf("decoded conflicting record's network_scope_id must match the primary fixture's")
	}
}
