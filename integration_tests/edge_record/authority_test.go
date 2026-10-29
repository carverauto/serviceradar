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
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/projection"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// The releases use isolated loopback node names and cookies. Connect their real
// ERTS nodes explicitly; core discovery and the trust fetch still run through
// the gateway's production CoreNodeForwarder and RecordTrust APIs.
func (h *harness) connectTrustCore(t *testing.T) {
	t.Helper()
	expr := fmt.Sprintf(`
node = String.to_atom(%q)
true = Node.set_cookie(node, String.to_atom(%q))
true = Node.connect(node)
Application.put_env(:serviceradar_agent_gateway, :cluster_core_node_basename, %q)
:ok = ServiceRadarAgentGateway.EdgeRecordTrustRefresh.refresh_now()
IO.puts("TRUST_READY")
`, h.coreProc.NodeName, h.coreProc.Cookie, strings.Split(h.coreProc.NodeName, "@")[0])
	out, err := h.gwProc.RPC(expr, rpcTimeout)
	if err != nil || !strings.Contains(out, "TRUST_READY") {
		t.Fatalf("connect gateway to core and refresh live trust: %v, output=%s", err, out)
	}
}

// Schedule through the same persisted assignment, plan and capability issuers
// that drive the deployed producer. Only the observations are invented by the
// fixture. No direct ledger/domain writes or fixture-only production path exist.
const prepareFixtureExpr = `
alias ServiceRadar.Actors.SystemActor
alias ServiceRadar.Infrastructure.{Agent, Partition}
alias ServiceRadar.Inventory.Device
alias ServiceRadar.SweepJobs.{ExecutionSlots, LeaseCapabilities, ProducerAssignments, SweepGroup}
alias ServiceRadar.Edge.{IssuerKey, SweepContract, SweepPlan}
alias Serviceradar.Edge.V1.{EdgeSignedCapabilityV1, EdgeSourceAuthorizationV1}
actor = SystemActor.system(:edge_record_composed_test)
input = Jason.decode!(Base.decode64!(__INPUT__))
scope = input["scope"] |> Base.decode64!() |> Ecto.UUID.cast!()
partition = ServiceRadar.Repo.get(Partition, scope) || (
  slug = "slice-" <> String.replace(scope, "-", "")
  Partition
  |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
  |> Ash.Changeset.force_change_attribute(:id, scope)
  |> Ash.create!()
)
agent_id = input["agent"]
if !ServiceRadar.Repo.get(Agent, agent_id) do
  device = Device
    |> Ash.Changeset.for_create(:create, %{uid: "device-" <> agent_id, ip: "198.51.100.254",
         hostname: agent_id, partition: partition.slug}, actor: actor)
    |> Ash.create!()
  Agent
  |> Ash.Changeset.for_create(:register, %{uid: agent_id, device_uid: device.uid}, actor: actor)
  |> Ash.create!()
end
group = SweepGroup
  |> Ash.Changeset.for_create(:create, %{name: "slice-" <> input["event"], partition: partition.slug,
       enabled: false, interval: "15m", agent_ids: [agent_id], static_targets: [input["target"]],
       sweep_modes: ["icmp", "tcp_connect"], ports: [443]}, actor: actor)
  |> Ash.create!()
{:ok, assignment} = ProducerAssignments.ensure(group.id, agent_id, partition.id)
{:ok, checks} = SweepPlan.checks(["icmp", "tcp_connect"], [443])
now = DateTime.add(DateTime.utc_now(), -60)
{:ok, slot} = ExecutionSlots.schedule(assignment, now, DateTime.add(now, 3600),
  targets: group.static_targets, check_set_sha256: SweepPlan.check_set_sha256(checks), lease_id: Ash.UUID.generate())
{:ok, key} = IssuerKey.configured()
{:ok, contract} = SweepContract.current()
{:ok, production} = LeaseCapabilities.production_capability(assignment, [slot], contract, key, now)
{:ok, [source]} = LeaseCapabilities.source_authorizations(assignment, slot, key)
IO.puts("SWEEP_AUTHORITY:" <> Jason.encode!(%{
  production: production |> EdgeSignedCapabilityV1.encode() |> Base.encode64(),
  source: source |> EdgeSourceAuthorizationV1.encode() |> Base.encode64(),
  plan_id: slot.plan_id |> Ecto.UUID.dump!() |> Base.encode64()
}))
`

func (h *harness) prepareFixture(t *testing.T, fx *FixtureRecord) {
	t.Helper()
	var record edgev1.EdgeRecordV1
	if err := proto.Unmarshal(fx.RecordBytes, &record); err != nil {
		t.Fatal(err)
	}
	input, err := json.Marshal(map[string]any{
		"scope": fx.NetworkScopeID, "agent": string(record.GetProducerContext().GetOriginPrincipalId()),
		"target": net.IP(fx.Batch.Hosts[0].Address).String() + "/30", "event": fmt.Sprintf("%x", fx.EventID),
	})
	if err != nil {
		t.Fatal(err)
	}
	expr := strings.ReplaceAll(prepareFixtureExpr, "__INPUT__", fmt.Sprintf("%q", base64.StdEncoding.EncodeToString(input)))
	out, err := h.coreProc.RPC(expr, rpcTimeout)
	if err != nil {
		t.Fatalf("schedule fixture execution: %v", err)
	}
	var authority struct {
		Production []byte `json:"production"`
		Source     []byte `json:"source"`
		PlanID     []byte `json:"plan_id"`
	}
	var encoded string
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "SWEEP_AUTHORITY:") {
			encoded = strings.TrimPrefix(line, "SWEEP_AUTHORITY:")
		}
	}
	if err := json.Unmarshal([]byte(encoded), &authority); err != nil {
		t.Fatalf("decode core-issued fixture authority: %v, output=%s", err, out)
	}
	production := new(edgev1.EdgeSignedCapabilityV1)
	source := new(edgev1.EdgeSourceAuthorizationV1)
	if err := proto.Unmarshal(authority.Production, production); err != nil {
		t.Fatal(err)
	}
	if err := proto.Unmarshal(authority.Source, source); err != nil {
		t.Fatal(err)
	}
	p := production.GetProduction()
	if p == nil || source.GetCapability().GetSource() == nil || len(authority.PlanID) != 16 {
		t.Fatal("core did not return complete scheduled authority")
	}
	record.ProductionCapability = production
	record.SourceAuthorization = source
	record.ProducerContext = &edgev1.EdgeProducerContext{
		OriginKind: p.OriginKind, OriginPrincipalId: p.OriginPrincipalId, ProducerInstanceId: p.ProducerInstanceId,
		ProducerAssignmentId: p.ProducerAssignmentId, RunId: p.RunId, RunShard: p.RunShard,
		AuthorityEpoch: proto.Uint64(p.AuthorityEpoch), ScopeId: p.ScopeId, ScopeSha256: p.ScopeSha256,
		PackageId: p.PackageId, PackageSha256: p.PackageSha256,
	}
	record.OutputContract.EffectiveGrantSha256 = p.EffectiveGrantSha256
	batch := fx.Batch
	batch.ExecutionId = source.ContextId
	batch.SweepGroupId = p.ScopeId
	batch.ExecutionShard = p.RunShard
	batch.AssignmentEpoch = p.AuthorityEpoch
	batch.ExecutionPlanId = authority.PlanID
	batch.ExecutionPlanSha256 = source.GetCapability().GetSource().ExecutionPlanSha256
	batch.TargetRangeId = source.ScopeId
	batch.TargetRangeSha256 = source.ScopeSha256
	batch.ObservedAtUnixNano = time.Now().UnixNano()
	record.Payload, err = proto.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	payloadSum := sha256.Sum256(record.Payload)
	record.PayloadSha256 = payloadSum[:]
	record.EncodedSize = uint32(len(record.Payload))
	record.UncompressedSize = record.EncodedSize
	record.ProjectedWriteBytes = uint64(projection.SweepRows(batch)) * 2048
	record.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(&record)
	if err := edgerecord.ValidateRecord(&record); err != nil {
		t.Fatalf("core-authorized fixture must validate: %v", err)
	}
	fx.RecordBytes, err = proto.Marshal(&record)
	if err != nil {
		t.Fatal(err)
	}
	recordSum := sha256.Sum256(fx.RecordBytes)
	fx.RecordSHA256 = recordSum[:]
	fx.SemanticEnvelopeSHA256 = record.SemanticEnvelopeSha256
	fx.ExecutionID, fx.ExecutionShard, fx.AssignmentEpoch = batch.ExecutionId, batch.ExecutionShard, batch.AssignmentEpoch
	for i := range fx.RowKeys {
		fx.RowKeys[i] = projection.RowKey(record.SemanticEnvelopeSha256, i)
	}

	// This is the production refresher, not a direct snapshot installation.
	_, err = h.gwProc.RPC(":ok = ServiceRadarAgentGateway.EdgeRecordTrustRefresh.refresh_now()", rpcTimeout)
	if err != nil {
		t.Fatalf("refresh newly issued assignment trust: %v", err)
	}
}

func (h *harness) assertSweepDomain(t *testing.T, fx *FixtureRecord) {
	t.Helper()
	execution := uuidLiteral(fx.ExecutionID)
	group := uuidLiteral(fx.Batch.SweepGroupId)
	count := len(fx.Batch.Hosts)
	if got := h.rpcQueryCount(t, fmt.Sprintf(`SELECT count(*) FROM platform.sweep_group_executions
WHERE id = %s AND sweep_group_id = %s AND status = 'completed'
AND hosts_total = %d AND hosts_available = %d AND hosts_failed = 0`, execution, group, count, count)); got != 1 {
		t.Fatalf("completed sweep execution with exact host counts missing: count=%d", got)
	}
	for _, host := range fx.Batch.Hosts {
		ip := net.IP(host.Address).String()
		if got := h.rpcQueryCount(t, fmt.Sprintf(`SELECT count(*) FROM platform.sweep_host_results
WHERE execution_id = %s AND ip = '%s' AND status = 'available'
AND hostname = '%s' AND open_ports = ARRAY[443] AND scanned_ports = ARRAY[443]`, execution, ip, host.Hostname)); got != 1 {
			t.Errorf("sweep result missing or wrong for %s: count=%d", ip, got)
		}
		if got := h.rpcQueryCount(t, fmt.Sprintf(`SELECT count(*) FROM platform.ocsf_devices d
JOIN platform.partitions p ON p.slug = d.partition
JOIN platform.device_agent_availability a ON a.device_uid = d.uid
WHERE p.id = %s AND d.ip = '%s' AND d.is_available = true
AND 'sweep' = ANY(d.discovery_sources) AND a.agent_id = '%s'
AND a.execution_id = %s AND a.sweep_group_id = %s AND a.is_available = true
AND a.open_ports = ARRAY[443]`, uuidLiteral(fx.NetworkScopeID), ip, h.certSet.AgentComponentID, execution, group)); got != 1 {
			t.Errorf("discovered device and agent availability missing or wrong for %s: count=%d", ip, got)
		}
	}
}

func (h *harness) testLiveAuthorityRevocation(t *testing.T) {
	fx, err := BuildSweepFixture([]byte(h.certSet.AgentComponentID))
	if err != nil {
		t.Fatal(err)
	}
	h.prepareFixture(t, fx)
	tlsCfg, err := h.certSet.AgentTLSConfig(h.gatewayServerName)
	if err != nil {
		t.Fatal(err)
	}
	firstSpool, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.sendUntilAccepted(t, tlsCfg, firstSpool, fx, pollTimeout); err != nil {
		t.Fatalf("current producer must be accepted before revocation: %v", err)
	}
	if h.awaitSingleLedgerRow(t, fx) != 1 {
		t.Fatal("current producer did not commit before revocation")
	}
	h.assertSweepDomain(t, fx)
	beforeMessages := len(h.storedMessagesCarrying(t, fx.RecordBytes))
	if beforeMessages != 1 {
		t.Fatalf("expected one accepted publication, got %d", beforeMessages)
	}
	expr := fmt.Sprintf(`{:ok, 1} = ServiceRadar.SweepJobs.ProducerAssignments.revoke_agents(%q, [%q])`,
		uuidText(fx.Batch.SweepGroupId), h.certSet.AgentComponentID)
	if _, err := h.coreProc.RPC(expr, rpcTimeout); err != nil {
		t.Fatalf("revoke scheduled producer: %v", err)
	}
	if _, err := h.gwProc.RPC(":ok = ServiceRadarAgentGateway.EdgeRecordTrustRefresh.refresh_now()", rpcTimeout); err != nil {
		t.Fatalf("refresh revoked producer fence: %v", err)
	}
	spoolID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatal(err)
	}
	msg, err := h.sendOneRawFrame(context.Background(), t, tlsCfg, spoolID, 1, fx.RecordBytes, fx.RecordSHA256, pollTimeout)
	if err != nil {
		t.Fatalf("send revoked producer record: %v", err)
	}
	disposition := requireSingleDisposition(t, msg, spoolID, 1,
		edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT)
	if string(disposition.GetEventId()) != string(fx.EventID) {
		t.Fatal("revocation disposition names the wrong event")
	}
	if len(h.storedMessagesCarrying(t, fx.RecordBytes)) != beforeMessages || h.rpcQueryCount(t, eventLedgerExistsSQL(fx.NetworkScopeID, fx.EventID)) != 1 {
		t.Fatal("revoked producer record changed the publication or committed event count")
	}
	if got := h.rpcQueryRow(t, deliverySlotSQL(fx.NetworkScopeID, []byte(h.certSet.AgentComponentID), spoolID, 1)); got != "NONE" {
		t.Fatalf("revoked producer delivery reached the database: %s", got)
	}
}

func uuidText(id []byte) string {
	return fmt.Sprintf("%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:])
}
