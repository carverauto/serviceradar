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
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
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

// TestBuildSweepFixtureInScopeSharesSpoolScope proves a fixture built for an
// existing spool carries that spool's network scope in its decoded record,
// still validates, and is a distinct record, so Group D's appends to the
// agent's spool never present the gateway a second scope.
func TestBuildSweepFixtureInScopeSharesSpoolScope(t *testing.T) {
	primary, err := BuildSweepFixture([]byte("vslice-agent-01"))
	if err != nil {
		t.Fatalf("BuildSweepFixture: %v", err)
	}
	next, err := BuildSweepFixtureInScope(primary.NetworkScopeID, []byte("vslice-agent-01"))
	if err != nil {
		t.Fatalf("BuildSweepFixtureInScope: %v", err)
	}

	if bytes.Equal(primary.EventID, next.EventID) || bytes.Equal(primary.ExecutionID, next.ExecutionID) {
		t.Fatalf("a scoped fixture must have its own event id and execution id")
	}
	if bytes.Equal(primary.SemanticEnvelopeSHA256, next.SemanticEnvelopeSHA256) {
		t.Fatalf("a scoped fixture must have its own semantic envelope digest")
	}

	var record edgev1.EdgeRecordV1
	if err := proto.Unmarshal(next.RecordBytes, &record); err != nil {
		t.Fatalf("scoped record bytes must decode: %v", err)
	}
	if err := edgerecord.ValidateRecord(&record); err != nil {
		t.Fatalf("scoped record must pass ValidateRecord: %v", err)
	}
	if !bytes.Equal(record.GetNetworkScopeId(), primary.NetworkScopeID) {
		t.Fatalf("decoded scoped record's network_scope_id must match the spool's scope")
	}
	if sum := sha256.Sum256(next.RecordBytes); !bytes.Equal(sum[:], next.RecordSHA256) {
		t.Fatalf("scoped fixture's RecordSHA256 must digest its RecordBytes")
	}
}

// TestFixtureContractRegistryAdmitsEveryFixture proves the registry snapshot the gateway boots with
// names exactly the contract reference both fixture variants carry. The gateway withholds a record
// whose bundle digest or snapshot differs from the registry entry, so a drift here would never
// publish Group A's record or would stop Group C's conflict frame before it reaches EventWriter.
func TestFixtureContractRegistryAdmitsEveryFixture(t *testing.T) {
	raw, err := FixtureContractRegistryJSON()
	if err != nil {
		t.Fatalf("FixtureContractRegistryJSON: %v", err)
	}
	var registry struct {
		RegistryEpoch          uint64 `json:"registry_epoch"`
		RegistrySnapshotSHA256 string `json:"registry_snapshot_sha256"`
		Contracts              []struct {
			ContractID           string `json:"contract_id"`
			ContractVersion      uint32 `json:"contract_version"`
			ContractBundleSHA256 string `json:"contract_bundle_sha256"`
			State                string `json:"state"`
			CostModelVersion     uint32 `json:"cost_model_version"`
		} `json:"contracts"`
	}
	if err := json.Unmarshal([]byte(raw), &registry); err != nil {
		t.Fatalf("registry JSON must decode: %v", err)
	}
	if len(registry.Contracts) != 1 || registry.Contracts[0].State != "active" {
		t.Fatalf("registry must hold exactly one active contract, got %+v", registry.Contracts)
	}
	entry := registry.Contracts[0]

	primary, err := BuildSweepFixture([]byte("vslice-agent-01"))
	if err != nil {
		t.Fatalf("BuildSweepFixture: %v", err)
	}
	conflict, err := BuildConflictingSweepFixture(primary.NetworkScopeID, []byte("vslice-agent-01"))
	if err != nil {
		t.Fatalf("BuildConflictingSweepFixture: %v", err)
	}

	for name, fx := range map[string]*FixtureRecord{"primary": primary, "conflict": conflict} {
		var record edgev1.EdgeRecordV1
		if err := proto.Unmarshal(fx.RecordBytes, &record); err != nil {
			t.Fatalf("%s record must decode: %v", name, err)
		}
		c := record.GetOutputContract()
		if c.GetContractId() != entry.ContractID ||
			c.GetContractVersion() != entry.ContractVersion ||
			hex.EncodeToString(c.GetContractBundleSha256()) != entry.ContractBundleSHA256 ||
			c.GetRegistryEpoch() != registry.RegistryEpoch ||
			hex.EncodeToString(c.GetRegistrySnapshotSha256()) != registry.RegistrySnapshotSHA256 ||
			record.GetCostModelVersion() != entry.CostModelVersion {
			t.Fatalf("%s fixture contract %+v does not match the registry entry %+v", name, c, entry)
		}
	}
}

// TestFixtureCapabilityVerifiesUnderGatewayTrustFile proves the fixture's
// production capability carries a real signature by the key the gateway trust
// file names, and that the trust file fences exactly the fixtures' producers
// and binds the harness agent to exactly their network scope, so the gateway's
// local authorization (task 3.2) accepts them.
func TestFixtureCapabilityVerifiesUnderGatewayTrustFile(t *testing.T) {
	fx, err := BuildSweepFixture([]byte("vslice-agent-01"))
	if err != nil {
		t.Fatalf("BuildSweepFixture: %v", err)
	}
	conflict, err := BuildConflictingSweepFixture(fx.NetworkScopeID, []byte("vslice-agent-01"))
	if err != nil {
		t.Fatalf("BuildConflictingSweepFixture: %v", err)
	}

	var record edgev1.EdgeRecordV1
	if err := proto.Unmarshal(fx.RecordBytes, &record); err != nil {
		t.Fatalf("record bytes must decode as EdgeRecordV1: %v", err)
	}

	path := filepath.Join(t.TempDir(), "trust.json")
	if err := WriteGatewayTrustFile(path, "vslice-agent-01"); err != nil {
		t.Fatalf("WriteGatewayTrustFile: %v", err)
	}

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read trust file: %v", err)
	}

	var document struct {
		TrustPolicyEpoch uint64 `json:"trust_policy_epoch"`
		Keys             []struct {
			IssuerID    string   `json:"issuer_id"`
			IssuerKeyID string   `json:"issuer_key_id"`
			PublicKey   string   `json:"public_key"`
			Purposes    []string `json:"purposes"`
		} `json:"keys"`
		Fences []struct {
			NetworkScopeID       string `json:"network_scope_id"`
			ProducerAssignmentID string `json:"producer_assignment_id"`
			RunShard             uint32 `json:"run_shard"`
			AuthorityEpoch       uint64 `json:"authority_epoch"`
		} `json:"fences"`
		Scopes []struct {
			AgentID         string   `json:"agent_id"`
			NetworkScopeIDs []string `json:"network_scope_ids"`
		} `json:"scopes"`
	}
	if err := json.Unmarshal(body, &document); err != nil {
		t.Fatalf("trust file must be JSON: %v", err)
	}
	if document.TrustPolicyEpoch == 0 || len(document.Keys) != 1 {
		t.Fatalf("trust file must pin a nonzero epoch and one key, got %+v", document)
	}

	key := document.Keys[0]
	publicKey, err := base64.StdEncoding.DecodeString(key.PublicKey)
	if err != nil {
		t.Fatalf("public key must be base64: %v", err)
	}
	capability := record.GetProductionCapability()
	if key.IssuerID != base64.StdEncoding.EncodeToString(capability.GetIssuerId()) ||
		key.IssuerKeyID != base64.StdEncoding.EncodeToString(capability.GetIssuerKeyId()) {
		t.Fatalf("trust file key does not name the capability's issuer/key id")
	}

	err = edgerecord.VerifyCapabilitySignature(
		capability, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION, ed25519.PublicKey(publicKey),
	)
	if err != nil {
		t.Fatalf("fixture production capability must verify under the trust file key: %v", err)
	}

	fixtures := []*FixtureRecord{fx, conflict}
	if len(document.Fences) != len(fixtures) {
		t.Fatalf("trust file fences %d producers, want exactly the %d fixture producers", len(document.Fences), len(fixtures))
	}
	if len(document.Scopes) != 1 || document.Scopes[0].AgentID != "vslice-agent-01" {
		t.Fatalf("trust file must bind exactly the harness agent, got %+v", document.Scopes)
	}
	boundScopes := document.Scopes[0].NetworkScopeIDs
	for _, candidate := range fixtures {
		var fenced edgev1.EdgeRecordV1
		if err := proto.Unmarshal(candidate.RecordBytes, &fenced); err != nil {
			t.Fatalf("fixture record bytes must decode: %v", err)
		}
		producer := fenced.GetProducerContext()
		found := false
		for _, fence := range document.Fences {
			if fence.NetworkScopeID == base64.StdEncoding.EncodeToString(fenced.GetNetworkScopeId()) &&
				fence.ProducerAssignmentID == base64.StdEncoding.EncodeToString(producer.GetProducerAssignmentId()) &&
				fence.RunShard == producer.GetRunShard() &&
				fence.AuthorityEpoch == producer.GetAuthorityEpoch() {
				found = true
			}
		}
		if !found {
			t.Errorf("trust file has no fence entry for fixture producer (run shard %d, authority epoch %d)",
				producer.GetRunShard(), producer.GetAuthorityEpoch())
		}
		if len(boundScopes) != 1 || boundScopes[0] != base64.StdEncoding.EncodeToString(fenced.GetNetworkScopeId()) {
			t.Errorf("trust file binds the harness agent to %v, want exactly the fixture's network scope", boundScopes)
		}
	}
}
