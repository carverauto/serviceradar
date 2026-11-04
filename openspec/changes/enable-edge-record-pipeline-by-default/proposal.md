# Change: Run the durable edge-record pipeline by default with a core-derived contract registry

## Why

The durable edge-record pipeline becomes the product's only agent data path in
the release that removes the legacy `StreamStatus` path, which is the release
this change ships in. Today it runs only when an operator turns it on through
Helm values (#6288, part of #6271):

- `edgeRecords.enabled` gates the gateway publisher and trust refresh
  (`AGENT_GATEWAY_EDGE_RECORDS_ENABLED`, `AGENT_GATEWAY_EDGE_RECORD_TRUST_SOURCE`),
  the core issuer key mount (`SERVICERADAR_EDGE_ISSUER_KEY_FILE`) and the
  gateway's NATS publish permissions for the edge-record subjects.
- The contract registry (`registry_epoch`, `registry_snapshot_sha256`, per-contract
  bundle digests) is hand-written JSON in `edgeRecords.contractRegistry`, rendered
  by `serviceradar.edgeRecordContractRegistry` into
  `SERVICERADAR_EDGE_RECORD_CONTRACT_REGISTRY` and
  `AGENT_GATEWAY_EDGE_RECORD_CONTRACT_REGISTRY`. Nothing verifies its digests
  against anything; they are operator-chosen labels.
- The bundled agent's producers each need their own `edgeRecords.agent*Enabled`
  value, and an edge agent installed by package or Ansible has no
  `edge_record_sender` block at all, so it never sends edge records.
- Core issues no standing grant and leases no sweep unless an operator turns the
  per-agent leasing switch on (`LeaseSettings`: "a deployment with no rows leases
  nothing").

serviceradar-control renders hosted tenant chart values in code and models none
of this, so hosted tenants cannot run the pipeline. Docker Compose installs cannot
either. Once the legacy path is removed, every such installation loses agent
telemetry. That makes this a release blocker.

The hand-written registry also makes every epoch change an operator procedure:
turn leasing off, wait for the last delivered slot, upgrade, turn leasing back on.
Skip a step and a record from the old epoch whose bundle the new document no
longer registers is withheld for good and caps the lane watermark.

## What Changes

- **BREAKING (chart)**: remove the `edgeRecords` values block. The chart fails to
  render, with a message naming the removed keys, when any `edgeRecords` key is
  set. No new Helm values replace it.
- The pipeline has no on/off switch anywhere: not in Helm, not in the
  environment, and not in CNPG. Core always issues, the gateway always admits and
  publishes, and the agent always runs its sender and spool.
  - The per-agent leasing switch (`leasing_enabled`) is removed. Standing grants
    and sweep leases follow agent capability and partition alone.
  - The agent's per-producer opt-ins are removed. A producer emits edge records
    whenever it holds the grant for its contract.
- Core derives the contract registry from the release's
  `ServiceRadar.Edge.ContractCatalog`.
  - Each bundle digest and the snapshot digest are a pure function of the catalog
    under a domain-separated hash grammar. A golden test pins them per release.
  - Core signs each epoch with the issuer key. The signature covers the epoch
    number, the snapshot digest, and each contract's bundle digest, admission
    fields and `projection_revision`, in canonical framing. Gateways verify it before installing a
    registry. Core verifies its persisted rows, and both sides verify any cached
    copy, on every load. A gateway that sees a bad signature refuses the
    document's registry, keeps its previous one, and surfaces the refusal.
  - Core persists registry epochs in CNPG. They only move forward and are
    numbered from a floor above every installation-static label.
- Gateways receive the registry, all non-retired epochs, from core in the same
  ERTS document as the edge trust snapshot. Agents receive only the contract
  references inside their signed grants and leases. EventWriter reads core's own
  epoch table.
- Epoch transitions are product-managed. Core records a new epoch as a candidate
  and activates it in one transaction once every live core node and every live
  gateway holds it. At activation it re-issues grants and re-leases slots that
  have not started under the new epoch. The previous epoch drains under its exact
  bundles until its capability horizon closes, then retires.
- A record stamped with an installation-static (pre-derivation) epoch resolves
  as a counted permanent rejection, never as a withhold, so it cannot cap a lane.
- Core stores its edge issuer seed in CNPG, encrypted with AshCloak, following
  `ManagedCertificatePolicyKey`. An upgrade imports the existing file seed once;
  a fresh install generates one. The cutover release keeps the `edge-issuer-seed`
  Secret key, its mount and `SERVICERADAR_EDGE_ISSUER_KEY_FILE` as the import
  input, and the release after cutover removes them (design Decision 6).
- Any condition that keeps an agent off the pipeline is visible on that agent:
  a partition with no row, a spool that cannot be opened, or no live gateway
  holding the active epoch. The `default` partition seed (#6270) gets a spec.
- The one remaining product knob, the agent spool byte budget, becomes a scoped
  runtime setting in CNPG with a code default of 1 GiB. It is delivered in the
  agent config. The lease horizon settings stay where they are.
- **BREAKING (release)**: this change ships in the same release as the legacy
  status-path removal (`move-agent-telemetry-to-edge-records` tasks 8.1 and 8.2;
  everything except RTSP and live media). There is no fallback release.
  - Package-installed and Ansible-installed agents get the default-on sender in
    that release from the agent build itself.
  - The farm01 7-day all-agents run (M4.1) is a gate before that release is cut.
  - A read-only readiness report ships ahead of it. It lists every agent that
    would be off the pipeline after the upgrade, with the reason.

## Impact

- Affected specs: edge-producer-data-plane, agent-connectivity, helm-deployment,
  database-bootstrap.
- Affected code:
  - Core: `ServiceRadar.Edge.ContractCatalog`, `ContractRegistryDocument`,
    `OutputContract`, `SweepContract`, `OutputGrants`, `IssuerKey`, `RecordTrust`,
    `ServiceRadar.SweepJobs.LeaseSettings`, `SweepLeaseSetting`, `LeasePass`, and
    the core and core_elx `runtime.exs`.
  - Gateway: `ServiceRadarAgentGateway.EdgeContractRegistry` and its `Static`
    source, `EdgeRecordTrust`, `EdgeRecordTrustRefresh`, and the gateway
    `runtime.exs`.
  - Agent: `go/pkg/agent/types.go` (`EdgeRecordSenderConfig`) and
    `go/cmd/agent` (`main.go`, `edge_record_sender.go`).
  - Chart: `helm/serviceradar` (`values.yaml`, `_helpers.tpl`, `core.yaml`,
    `agent-gateway.yaml`, `nats.yaml`, `files/serviceradar-config.yaml`,
    `secret-generator-job.yaml`, `README.md`, and the edge-record tests).
  - Tests and docs: `integration_tests/edge_record`, `docs/docs/data-pipeline.md`,
    `docs/docs/native-addons.md`.
- Supersedes part of `add-edge-contract-registry-lifecycle`: the registry source,
  the activation and drain protocol, stale-component fencing and registry-epoch
  signing (its tasks 1.1, 1.5, 1.6 for readiness and epoch selection, and 1.7,
  except security revocation). That change keeps the deterministic cost API,
  security revocation and Hello advertisement. Its proposal records the split, and
  its lifecycle requirement is amended to match this change.
- Amends the pending `move-agent-telemetry-to-edge-records` requirement "Agent-scheduled
  producers emit under standing output grants". Grants no longer depend on an
  operator switch.
- External:
  - serviceradar-control needs a values guard, and its tenant upgrade planning
    must handle the one-release jump to no legacy (design.md,
    "serviceradar-control"). No new values are involved.
  - The packages and the serviceradar-ansible role must create the agent runtime
    directory.
  - Installs that set `edgeRecords` (two internal lab and demo installs) must
    delete the block before upgrading.
- Ships in the same release as the legacy-path removal (sibling tasks 8.1 and 8.2).
