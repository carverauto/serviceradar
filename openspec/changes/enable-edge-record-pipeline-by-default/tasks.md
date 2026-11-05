# Tasks: Run the durable edge-record pipeline by default with a core-derived contract registry

## 0. Decisions and cross-change reconciliation

- [x] 0.1 Get product-owner answers to the open questions and record them in
  design.md ("Resolved Questions", 2026-11-03).
- [ ] 0.2 Sign registry epochs (design Decision 12):
  - [x] 0.2.1 Implement the epoch signing preimage in `HashGrammar` framing. It
    covers the domain tag `serviceradar.edge.contract_registry_epoch.v1`, the
    format version, the epoch number, the snapshot digest, and each contract
    sorted by `(contract_id, contract_version)`: its id, version, bundle digest,
    route profile, traffic class, partition rule, cost model version and
    `projection_revision`. Sign it
    with the issuer key when the candidate row is inserted. Store `signature` and
    `signing_key_id` in the row.
  - [ ] 0.2.2 Verify on every load in core: the epoch reader verifies each CNPG row
    and any cached copy before use. On failure it excludes the epoch, signs
    nothing under it, and reports `registry_epoch_signature_invalid` in pipeline
    status. A bad active epoch stops all new signing.
    (Done except the pipeline-status report, which lands with 1.8: the reader
    returns the refused rows with that reason and logs them at error.)
  - [x] 0.2.3 Carry the signature and key id per epoch, and `projection_revision`
    on every contract entry, in the trust document's `contract_registry` member.
  - [x] 0.2.4 Gateway verification: verify every epoch against the issuer public
    key its key id names before installing the registry member, and re-verify any
    persisted or `:persistent_term` copy on load. On a bad signature:
    - refuse the whole member, keep the previously verified registry, and still
      install the document's trust;
    - log the epoch and key id at error, increment
      `edge_registry_signature_rejected`, and report the refusal on the next
      refresh;
    - do not count as holding the candidate.

    (`ServiceRadarAgentGateway.EdgeRecordTrust` and `EdgeContractRegistry.verify_member/2`.
    The `:persistent_term` snapshot is written only by `install/2` after verification and read
    as-is on the frame path; the one copy reused across documents, the registry kept after a
    refusal, is re-verified under the new document's keys first and dropped if it fails.)
  - [x] 0.2.5 Tests:
    - a golden preimage and signature vector;
    - a tampered admission field, projection revision, epoch number or bundle
      digest each failing verification;
    - a tampered CNPG row excluded by core;
    - a gateway refusing a bad document while keeping its previous registry;
    - a fresh gateway with only a bad document withholding as
      `registry_unavailable`.

    (Core vectors: `contract_registry_epoch_document_test.exs` and
    `contract_registry_db_test.exs`. Gateway cases: `edge_record_trust_test.exs`.)
- [x] 0.3 Re-scope `add-edge-contract-registry-lifecycle` tasks 1.1, 1.5, 1.6 and
  1.7 to what remains after this change (cost API, security revocation, Hello
  advertisement). Amend its lifecycle requirement: no `ready` state, readiness
  from every live core node and gateway, agents never hold the registry. Keep its
  "signed" wording.
- [ ] 0.4 Update #6271's line for `add-edge-contract-registry-lifecycle`.

## 1. Core: registry derivation and epochs

- [x] 1.1 Add `projection_revision` and the payload message module to every
  `ContractCatalog` entry. Implement the bundle digest and the snapshot digest
  in `HashGrammar` framing (design Decision 2). Verify the generated protobuf
  modules expose enough of the message definition for the schema fingerprint.
  If they do not, generate the descriptors rather than hashing source text.
- [x] 1.2 Add the golden digest test for the current catalog, with an
  append-only `(projection_revision, digest)` history per contract id and
  version that fails on a change without a bump, a decreasing revision, or a
  repeated digest. Put the projector row-output tests next to it.
  (`test/serviceradar/edge/contract_bundle_golden_test.exs` and
  `test/fixtures/edge/contract_bundle_history_v1.json`, beside
  `projection_rows_test.exs`.)
- [x] 1.3 Add `platform.edge_contract_registry_epochs` (Decision 4) as an Ash
  resource with a migration, and add it to `SchemaBootstrap` and the baseline.
  Enforce one `active` row, one `candidate` row and a unique digest among rows not
  retired unactivated with partial unique indexes, and insert-only documents.
  Include a durable `last_matched_at` column.
  Number epochs from 1_000_000.
  (Migration `20261104130000`. The table needs no bootstrap rows, and a fresh
  install applies the migration on top of the committed baseline, so neither
  `SchemaBootstrap` nor the baseline changes. A trigger refuses content updates
  and backward state moves.)
- [ ] 1.4 Epoch insertion, signing and projection rules (Decision 4):
  - [x] Insert the candidate on boot, idempotently by digest, retiring any older
    candidate unactivated in the same transaction. Activate the first epoch
    immediately when none is active. Superseded-catalog nodes never insert or
    claim a candidate.
  - [x] Every node signs under the active epoch's verified document, and only
    the entries whose exact bundle digest its own catalog holds.
  - [ ] Delivery grants for draining-epoch backlog follow the projection rule
    instead.
  - [ ] Project by compatibility: same contract id and version, and the node's
    `projection_revision` at least the record's bundle revision.
  - [ ] For a bundle no live core can project: revoke its grants and leases,
    publish the projectable bundle set with the trust document, and move
    bulk-stream records to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` under
    `awaiting_roll_forward` with their original bytes, redriving them through
    the ledger on roll-forward. When the full dead-letter stream refuses a copy,
    acknowledge the bulk delivery (never NAK), count the loss once per record
    (by `Sr-Edge-Delivery-Id`) per contract and bundle as
    `awaiting_roll_forward_overflow`, and raise a managed alert.
  - [ ] Refresh `last_matched_at` from the coordinator while a live core node
    matches the candidate, retire the candidate unactivated once it is older
    than a full capability-lifetime window, and drop it from the trust
    document. Superseded nodes never count toward readiness.
- [ ] 1.5 Replace `ContractRegistryDocument.parse/1` from the environment with one
  cached epoch reader. `OutputContract.current/1` reads the active epoch, and
  validation and projection read the record's own epoch. Delete the
  `SERVICERADAR_EDGE_RECORD_CONTRACT_REGISTRY` reads in both core `runtime.exs`
  files. (Done except validation and projection by the record's own epoch,
  which lands with the projection rule in 1.4.)
- [ ] 1.6 Run the transition in the coordinator (Decision 5): candidate readiness
  from live core nodes and live gateways, atomic activation, agent config
  invalidation, grant re-signing, and superseding plus re-leasing of unstarted
  slots. Verify against `LeasePass` and the agent lease merge rules that a
  superseding lease replaces unstarted slots without stranding a started one.
- [ ] 1.7 Compute `drain_until` at activation and retire on schedule. Keep issuing
  delivery grants for draining epochs, and never issue them for retired ones.
- [ ] 1.8 Add pipeline status: the `awaiting_roll_forward` counts (agent spool
  refusals and dead-lettered records) and `awaiting_roll_forward_overflow`, the
  active,
  candidate and draining epochs, the components not holding a candidate, and the issuer key presence. Expose it
  through core's health API.

## 2. Core: issuer key, switch removal, settings, conditions

- [x] 2.1 Add `ServiceRadar.Edge.EdgeIssuerKeyRecord`, an AshCloak singleton
  modeled on `ManagedCertificatePolicyKey`. Make `IssuerKey.configured/0`
  ensure-then-cache. Delete `load_file!/1` and the `SERVICERADAR_EDGE_ISSUER_KEY_FILE`
  reads.
  - Revised (design Decision 6, 2026-11-04): the first store imports the seed of
    `SERVICERADAR_EDGE_ISSUER_KEY_FILE` when one is configured, so epochs, grants and
    leases signed with the file key keep verifying. `load_file!/1` stays deleted;
    the runtime config passes only the path. The chart (5.2) keeps the mount and the
    env var for the cutover release; 5.7 removes them in the release after.
- [x] 2.2 Rename `platform.sweep_lease_settings` to `platform.edge_pipeline_settings`.
  Drop `leasing_enabled` and add `spool_max_bytes`. Remove `enabled?` from
  `LeaseSettings`, and remove its uses in `LeasePass` and `OutputGrants`. Grants
  and leases now depend on partition resolution and agent capability.
  - The resource and resolver are now `ServiceRadar.Edge.PipelineSetting` and
    `ServiceRadar.Edge.PipelineSettings`. `spool_max_bytes` has a 16 MiB floor.
- [x] 2.3 Revoke an agent's standing grants when its identity is superseded
  (`Infrastructure.Agent` `:supersede`) or its certificate is revoked. Find
  every writer of those states, not just the obvious action, and reactivate on
  `:revive_superseded`.
  - `:supersede` is the only way into `:superseded` (state machine); a change on it
    revokes in the same transaction. Certificate revocation has two writers: the
    managed component authority (`revoke_component`, `revoke_component_certificate`;
    a renewal's `successor-observed` retirement is not a revocation) and the
    gateway agent-certificate revoke API. Reactivation is the next config the agent
    fetches after it authenticates again, as for a partition move.
- [x] 2.4 Deliver the resolved spool budget in `AgentConfigResponse`. Default it
  to 1 GiB.
  - `AgentConfigResponse.edge_spool_max_bytes`; the budget is part of the config
    version.
- [ ] 2.5 Record the per-agent edge pipeline condition (`partition_not_found`,
  `no_live_gateway_on_active_epoch`, `spool_unavailable`). Expose it in the agent
  API representation and in web-ng's agent detail.
  - [x] The `edge_pipeline_conditions` calculation on the agent (JSON:API and
    `GET /api/admin/agents`) and the agent detail card, with `partition_not_found`
    and the readiness reasons of 7.1.
  - [x] `spool_unavailable`, from the spool status the agent reports in its hello
    (4.3), for connected agents.
  - [ ] `no_live_gateway_on_active_epoch` (needs the epochs of 1.3 and the gateway
    installed-digest report of 2.6 and 3.4).
- [x] 2.6 Extend `RecordTrust.snapshot/0` with the `contract_registry` member
  (format 2, every non-retired epoch), and accept the gateway's
  installed-digest report on the refresh call.

## 3. Gateway

- [x] 3.1 Install trust and registry together in `EdgeRecordTrust`. Delete
  `EdgeContractRegistry.Static` and `AGENT_GATEWAY_EDGE_RECORD_CONTRACT_REGISTRY`.
- [x] 3.2 Admit each record against the entry of the epoch it names, across all held
  epochs. Replace `:historical_bundle_not_registered` with the per-epoch lookup.
  Reject `registry_epoch_retired` and `static_registry_epoch` permanently, and
  order the static-era check ahead of any withhold, including issuer key id
  lookup.
- [x] 3.3 Delete `AGENT_GATEWAY_EDGE_RECORDS_ENABLED` so the publisher always
  starts, and make core the default trust source. Rewrite the `runtime.exs`
  comment that says the pipeline stays off. (No harness used the boot-time file
  source, so it is deleted with `AGENT_GATEWAY_EDGE_RECORD_TRUST_SOURCE` and
  `AGENT_GATEWAY_EDGE_RECORD_TRUST_FILE`: core is the only trust source.)
- [x] 3.4 Report installed snapshot digests on each refresh.
- [ ] 3.5 Refuse a record whose bundle is outside the projectable set in the
  trust document with a retryable refusal, so the agent keeps it spooled.
  (Gateway side done: the member's optional `"projectable_bundles"`, a list of
  lowercase-hex bundle digests, withholds any other bundle as
  `:bundle_not_projectable`. Core does not publish the set yet (1.4), so an
  absent key means no restriction. When 1.4 lands, make the key required in
  `EdgeContractRegistry.verify_member/2` and delete the `nil` clause of its
  `projectable/2`, then check this.)

## 4. Agent

- [x] 4.1 Make the sender and spool unconditional. Default `spool_dir` to
  `<runtime base>/edge-records`. Delete `Enabled`, `SweepEnabled`,
  `MetricsEnabled`, `TelemetryEnabled` and `PluginResultsEnabled`, and wire
  every producer's spool unconditionally. Keep the grant as the only gate.
  Delete `ProducersEnabled()` and persist terminal dispositions always.
  - The `DiscoveryEnabled`, `SyncEnabled` and `MaxBytes` fields went too. The
    default directory is `DefaultEdgeRecordSpoolDir()`. A spool that cannot be
    opened does not stop the agent. An older config that still sets the removed
    keys loads, and the removed keys are ignored.
- [x] 4.2 Apply the config-delivered spool budget at admission.
  - The agent starts on 1 GiB. `AgentConfigResponse.edge_spool_max_bytes` moves
    the allocator ceiling (`Allocator.SetCapacity`) and the gate marks
    (`Gate.SetWatermarks`) together. A lower budget evicts nothing.
- [x] 4.3 Report `spool_unavailable` in agent status when the spool cannot be opened.
  - `EdgeRecordSpoolStatus` on both hellos (`AgentHelloRequest.edge_record_spool`,
    `ControlStreamHello.edge_record_spool`). The gateway records it in the agent's
    metadata.

## 5. Chart, Compose, docs

- [x] 5.1 Remove the `edgeRecords` block from `values.yaml`, along with the
  `serviceradar.edgeRecordContractRegistry` helper. Add the fail guard for any
  `edgeRecords` key.
  - `serviceradar.rejectRemovedEdgeRecordValues`, included from the always-rendered
    `serviceradar-config` ConfigMap. It fails on the key's presence, so an empty
    `edgeRecords: {}` fails too. The message carries no version number.
- [x] 5.2 Clean up the core and gateway manifests:
  - `core.yaml`: keep the issuer volume and `SERVICERADAR_EDGE_ISSUER_KEY_FILE`
    in the cutover release, no longer gated on `edgeRecords`, solely as the
    one-time import input (design Decision 6). A configured file that is missing
    stores no key, so set them only where the Secret carries `edge-issuer-seed`.
    Remove `SERVICERADAR_EDGE_RECORD_CONTRACT_REGISTRY`. Task 5.7 removes the
    issuer volume and env var in the following release.
  - `agent-gateway.yaml`: remove the env block and the `natsPublishingEnabled`
    clause.
  - `nats.yaml`: make the edge-record subject permissions unconditional.
  - "Where the Secret carries `edge-issuer-seed`" is rendered as
    `secrets.autoGenerate` not false: the pre-install/pre-upgrade secret generator
    then guarantees the key before core starts. With an operator-owned Secret the
    chart cannot know (a `lookup` is empty under Argo CD), so core is not pointed at
    the file and generates its own key.
  - The gateway's NATS URL, TLS, server name, creds file and creds mount no longer
    depend on any status-path publisher, because the edge-record publisher always
    needs NATS. The edge-record subjects reach core's callout grants through the
    shared `serviceradar.natsStaticUsers` list (`serviceradar-nats-static-users`).
- [x] 5.3 Clean up the agent config and secret generation:
  - `files/serviceradar-config.yaml`: remove the `edge_record_sender` block and its
    guards.
    - The enable flag, producer opt-ins, `max_bytes` and both guards are gone. The
      block keeps only `spool_dir`, derived from `agent.runtimeStorage.basePath`,
      so the bundled agent's spool stays on the volume the chart mounts there when
      an operator moves it. That is host layout (Decision 1), not a pipeline value.
  - `secret-generator-job.yaml`: keep `edge-issuer-seed` in `REQUIRED_KEYS`, the
    generated JSON and the patch list for the cutover release (task 5.7 removes
    it).
- [x] 5.4 Update the chart tests: `tests/edge_records_test.yaml`,
  `tests/edge_record_nats_permissions_test.yaml` and
  `edge_record_agent_config_test.py`. Assert the fail guard, the unconditional
  permissions, and that the core issuer mount and
  `SERVICERADAR_EDGE_ISSUER_KEY_FILE` are present in the cutover release.
- [x] 5.5 Rewrite the "Durable edge-record canary" section of the chart
  README. Update `docs/docs/data-pipeline.md`, adding "Upgrading from the static
  registry" with the optional drain, and `docs/docs/native-addons.md`.
- [x] 5.6 Confirm that Docker Compose needs no change: the agent's
  `/var/lib/serviceradar` volume holds the default spool directory, and
  `CLOAK_KEY` is present for the issuer key row.
  - Both hold (`agent-data` at `/var/lib/serviceradar`; `CLOAK_KEY_FILE` on
    core-elx). Compose did need one change: its agent-gateway had no NATS
    connection at all, so the always-on edge-record publisher could not publish.
    It now gets `AGENT_GATEWAY_NATS_*` and the platform creds, as core-elx does.
- [ ] 5.7 Release after cutover, once every install has imported its seed: remove
  the core issuer mount, `SERVICERADAR_EDGE_ISSUER_KEY_FILE`, `edge-issuer-seed`
  from the secret generator, the `:edge_issuer_key_import_file` runtime config in
  both `runtime.exs` files, and the import code path in `IssuerKey`. Flip the
  chart test to assert no issuer mount.

## 6. Tests

Load the `test-audit` skill before writing these.

- [ ] 6.1 Core tests:
  - digest determinism across processes;
  - candidate insert convergence under concurrency;
  - first-epoch immediate activation;
  - readiness gating, with one gateway missing and one core node on an old catalog;
  - atomic activation and re-lease;
  - retirement time;
  - superseded-node signing under the active epoch, including B to C to a
    rollback to B;
  - a whole-fleet rollback after a contract version bump: no new signatures and
    revoked grants for the bumped entry, unchanged entries still signed, gateway
    retryable refusals, bulk-stream records dead-lettered as
    `awaiting_roll_forward` with original bytes, and all of them drained or
    redriven after roll-forward; with a full dead-letter stream, each refused
    record acknowledged and counted once as `awaiting_roll_forward_overflow`
    with an alert, and with more overflowed records than `max_ack_pending`,
    other contracts still projecting;
  - a forward upgrade that changes a bundle at the same contract version: the old
    backlog gets delivery grants, projects on the new release and nothing awaits
    roll-forward;
  - a revert at the same contract version: the revision still increases and the
    prior revision's backlog projects;
  - a newer candidate retiring the older one unactivated, and roll-forward then
    rollback retiring the abandoned candidate after the capability-lifetime
    window, measured from `last_matched_at` across a coordinator failover, while
    the active epoch stays put;
  - issuer key insert-only race and restart stability;
  - a fresh install issuing grants with zero settings rows.

  Unboxed tests delete what they create.
- [x] 6.2 Gateway tests: draining-epoch admission with a changed bundle, retired
  and static-era permanent rejection (including with an unknown key id), and an
  expired or unparseable registry withholding.
- [ ] 6.3 Agent tests: no `edge_record_sender` block opens the default spool and
  runs the sender, a producer emits only while holding its grant, and the budget
  is applied from config.
- [ ] 6.4 Integration: move `integration_tests/edge_record` off
  `SERVICERADAR_EDGE_ISSUER_KEY_FILE` and the registry env vars, and add an epoch
  change across a core restart with spooled backlog that drains.
  - [x] Off `SERVICERADAR_EDGE_ISSUER_KEY_FILE`: the harness stores its synthetic
    key in CNPG through the core release, before trust is connected.

## 7. Cutover release coupling (design Decision 13)

- [x] 7.1 Ahead of the cutover release, ship the read-only edge pipeline readiness
  report. It lists every agent that would be off the pipeline after the upgrade,
  with the reasons `partition_not_found`, `agent_upgrade_blocked` (pinned,
  rollout paused, or no artifact for its platform) and `agent_disconnected`.
  Show it in the API and in web-ng, and change no behavior.
  - `ServiceRadar.Edge.PipelineReadiness`; `GET /api/admin/agents/edge-pipeline-readiness`;
    Settings > Agents > Edge Pipeline Readiness. `agent_upgrade_blocked` reports a
    paused rollout, no published release, or no artifact in the newest published
    release for the agent's platform. The product has no agent version pin, so
    "pinned" has nothing to read and is not reported. Agents that run from a
    container image are upgraded with the image and are never blocked.
- [ ] 7.2 Put `move-agent-telemetry-to-edge-records` tasks 8.1 and 8.2 (remove
  every legacy agent emission and the gateway publishers that serve them, except
  RTSP and live media) in the same release as this change. Confirm its family
  soaks (tasks 2 to 7) passed before the release is cut.
- [ ] 7.3 Make the packages for every published agent platform, and the
  `serviceradar-ansible` agent role, create the agent runtime directory writable
  by the agent user. Verify that a package-installed agent with no
  `edge_record_sender` block opens its spool on first start.
- [ ] 7.4 Add `agent_upgrade_pending` to the per-agent conditions, for agents still
  on a pre-cutover build after core upgrades. Make the release rollout target
  every agent at core upgrade.
  - [x] `agent_upgrade_pending`: a connected agent whose hello carries no spool status
    runs a build from before the default-on sender.
  - [ ] Target every agent with the release rollout at core upgrade. Not started: the
    core has no automatic publication of its own agent release to roll out (releases
    are imported by an operator), so this needs a design for which release and
    artifacts core targets.

## 8. Rollout

- [ ] 8.1 farm01, release candidate:
  - Optional drain: on the old release, turn leasing off and wait for spool depth
    zero.
  - Delete `edgeRecords` from its values and deploy the cutover release
    candidate.
  - Confirm that the first derived epoch is active and verified, grants are
    re-signed, and lanes advance.
- [ ] 8.2 M4.1 pre-release gate: every farm01 agent on the release candidate for 7
  days with tracking evidence, including its package agents. Cut the release
  only after the gate passes. A failure blocks the release.
- [ ] 8.3 demo: delete `edgeRecords` in the gitops commit that bumps the chart.
- [ ] 8.4 serviceradar-control: file the issue drafted in design.md. Land the values
  guard and readiness-gated tenant upgrade planning before the hosted fleet takes
  the cutover chart.

## 9. Validate

- [ ] 9.1 Run the Go, Elixir, chart and Bazel suites for every touched target, plus
  `openspec validate enable-edge-record-pipeline-by-default --strict`.
