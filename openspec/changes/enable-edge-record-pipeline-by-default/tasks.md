# Tasks: Run the durable edge-record pipeline by default with a core-derived contract registry

## 0. Decisions and cross-change reconciliation

- [ ] 0.1 Get product-owner answers to design.md Open Questions 1-4 and record them
  in design.md.
- [ ] 0.2 Reconcile the wording of the pending requirements that conflict with this
  change, before any of these changes archives:
  - In `add-edge-contract-registry-lifecycle`, "Output contract bundles have a
    governed deployment lifecycle" still uses "signed" and expects target agent
    cohorts to attest.
  - In `move-agent-telemetry-to-edge-records`, "Each data family and scheduling
    model has one typed output contract" says "signed contract registry".

  Apply the Open Question 3 answer. Then `grep -rn` each changed sentence across
  `openspec/changes` (excluding `archive/`) and fix every pending copy.
- [ ] 0.3 Re-scope `add-edge-contract-registry-lifecycle` tasks 1.1, 1.5, 1.6 and
  1.7 to what remains after this change (cost API, security revocation, Hello
  advertisement), and update #6271's line for that change.

## 1. Core: registry derivation and epochs

- [ ] 1.1 Add `projection_revision` and the payload message module to every
  `ContractCatalog` entry. Implement the bundle digest and the snapshot digest
  in `HashGrammar` framing (design Decision 2). Verify the generated protobuf
  modules expose enough of the message definition for the schema fingerprint.
  If they do not, generate the descriptors rather than hashing source text.
- [ ] 1.2 Add the golden digest test for the current catalog. Put the projector
  row-output tests next to it.
- [ ] 1.3 Add `platform.edge_contract_registry_epochs` (Decision 4) as an Ash
  resource with a migration, and add it to `SchemaBootstrap` and the baseline.
  Enforce one `active` row with a partial unique index and insert-only documents.
  Number epochs from 1_000_000.
- [ ] 1.4 Insert the candidate on boot, idempotently by digest. Activate the first
  epoch immediately when none is active. Fence stale-catalog nodes from signing.
- [ ] 1.5 Replace `ContractRegistryDocument.parse/1` from the environment with one
  cached epoch reader. `OutputContract.current/1` reads the active epoch, and
  validation and projection read the record's own epoch. Delete the
  `SERVICERADAR_EDGE_RECORD_CONTRACT_REGISTRY` reads in both core `runtime.exs`
  files.
- [ ] 1.6 Run the transition in the coordinator (Decision 5): candidate readiness
  from live core nodes and live gateways, atomic activation, agent config
  invalidation, grant re-signing, and superseding plus re-leasing of unstarted
  slots. Verify against `LeasePass` and the agent lease merge rules that a
  superseding lease replaces unstarted slots without stranding a started one.
- [ ] 1.7 Compute `drain_until` at activation and retire on schedule. Keep issuing
  delivery grants for draining epochs, and never issue them for retired ones.
- [ ] 1.8 Add pipeline status: the active, candidate and draining epochs, the
  components not holding a candidate, and the issuer key presence. Expose it
  through core's health API.

## 2. Core: issuer key, switch removal, settings, conditions

- [ ] 2.1 Add `ServiceRadar.Edge.EdgeIssuerKeyRecord`, an AshCloak singleton
  modeled on `ManagedCertificatePolicyKey`. Make `IssuerKey.configured/0`
  ensure-then-cache. Delete `load_file!/1` and the `SERVICERADAR_EDGE_ISSUER_KEY_FILE`
  reads.
- [ ] 2.2 Rename `platform.sweep_lease_settings` to `platform.edge_pipeline_settings`.
  Drop `leasing_enabled` and add `spool_max_bytes`. Remove `enabled?` from
  `LeaseSettings`, and remove its uses in `LeasePass` and `OutputGrants`. Grants
  and leases now depend on partition resolution and agent capability.
- [ ] 2.3 Revoke an agent's standing grants when its identity is superseded
  (`Infrastructure.Agent` `:supersede`) or its certificate is revoked. Find
  every writer of those states, not just the obvious action, and reactivate on
  `:revive_superseded`.
- [ ] 2.4 Deliver the resolved spool budget in `AgentConfigResponse`. Default it
  to 1 GiB.
- [ ] 2.5 Record the per-agent edge pipeline condition (`partition_not_found`,
  `no_live_gateway_on_active_epoch`, `spool_unavailable`). Expose it in the agent
  API representation and in web-ng's agent detail.
- [ ] 2.6 Extend `RecordTrust.snapshot/0` with the `contract_registry` member
  (format 2, every non-retired epoch), and accept the gateway's
  installed-digest report on the refresh call.

## 3. Gateway

- [ ] 3.1 Install trust and registry together in `EdgeRecordTrust`. Delete
  `EdgeContractRegistry.Static` and `AGENT_GATEWAY_EDGE_RECORD_CONTRACT_REGISTRY`.
- [ ] 3.2 Admit each record against the entry of the epoch it names, across all held
  epochs. Replace `:historical_bundle_not_registered` with the per-epoch lookup.
  Reject `registry_epoch_retired` and `static_registry_epoch` permanently, and
  order the static-era check ahead of any withhold, including issuer key id
  lookup.
- [ ] 3.3 Delete `AGENT_GATEWAY_EDGE_RECORDS_ENABLED` so the publisher always
  starts, and make core the default trust source. Rewrite the `runtime.exs`
  comment that says the pipeline stays off.
- [ ] 3.4 Report installed snapshot digests on each refresh.

## 4. Agent

- [ ] 4.1 Make the sender and spool unconditional. Default `spool_dir` to
  `<runtime base>/edge-records`. Delete `Enabled`, `SweepEnabled`,
  `MetricsEnabled`, `TelemetryEnabled` and `PluginResultsEnabled`, and wire
  every producer's spool unconditionally. Keep the grant as the only gate.
  Delete `ProducersEnabled()` and persist terminal dispositions always.
- [ ] 4.2 Apply the config-delivered spool budget at admission.
- [ ] 4.3 Report `spool_unavailable` in agent status when the spool cannot be opened.

## 5. Chart, Compose, docs

- [ ] 5.1 Remove the `edgeRecords` block from `values.yaml`, along with the
  `serviceradar.edgeRecordContractRegistry` helper. Add the fail guard for any
  `edgeRecords` key.
- [ ] 5.2 Clean up the core and gateway manifests:
  - `core.yaml`: remove the issuer volume and both env vars.
  - `agent-gateway.yaml`: remove the env block and the `natsPublishingEnabled`
    clause.
  - `nats.yaml`: make the edge-record subject permissions unconditional.
- [ ] 5.3 Clean up the agent config and secret generation:
  - `files/serviceradar-config.yaml`: remove the `edge_record_sender` block and its
    guards.
  - `secret-generator-job.yaml`: remove `edge-issuer-seed` from `REQUIRED_KEYS`,
    the generated JSON and the patch list.
- [ ] 5.4 Update the chart tests: `tests/edge_records_test.yaml`,
  `tests/edge_record_nats_permissions_test.yaml` and
  `edge_record_agent_config_test.py`. Assert the fail guard, the unconditional
  permissions, and no issuer mount.
- [ ] 5.5 Rewrite the "Durable edge-record canary" section of the chart
  README. Update `docs/docs/data-pipeline.md`, adding "Upgrading from the static
  registry" with the optional drain, and `docs/docs/native-addons.md`.
- [ ] 5.6 Confirm that Docker Compose needs no change: the agent's
  `/var/lib/serviceradar` volume holds the default spool directory, and
  `CLOAK_KEY` is present for the issuer key row.

## 6. Tests

Load the `test-audit` skill before writing these.

- [ ] 6.1 Core tests:
  - digest determinism across processes;
  - candidate insert convergence under concurrency;
  - first-epoch immediate activation;
  - readiness gating, with one gateway missing and one core node on an old catalog;
  - atomic activation and re-lease;
  - retirement time;
  - stale-node fencing;
  - issuer key insert-only race and restart stability;
  - a fresh install issuing grants with zero settings rows.

  Unboxed tests delete what they create.
- [ ] 6.2 Gateway tests: draining-epoch admission with a changed bundle, retired
  and static-era permanent rejection (including with an unknown key id), and an
  expired or unparseable registry withholding.
- [ ] 6.3 Agent tests: no `edge_record_sender` block opens the default spool and
  runs the sender, a producer emits only while holding its grant, and the budget
  is applied from config.
- [ ] 6.4 Integration: move `integration_tests/edge_record` off
  `SERVICERADAR_EDGE_ISSUER_KEY_FILE` and the registry env vars, and add an epoch
  change across a core restart with spooled backlog that drains.

## 7. Rollout

- [ ] 7.1 farm01: on the old release, turn leasing off and wait for spool depth zero
  (Open Question 2). Delete `edgeRecords` from its values, upgrade, and confirm
  the first derived epoch is active, grants are re-signed and lanes advance.
- [ ] 7.2 demo: delete `edgeRecords` in the gitops commit that bumps the chart.
- [ ] 7.3 serviceradar-control: file the issue drafted in design.md and land its
  guard and release gate before the hosted fleet takes this chart.
- [ ] 7.4 Ship the legacy removal (`move-agent-telemetry-to-edge-records` task 8.1)
  only in a release after this one.

## 8. Validate

- [ ] 8.1 Run the Go, Elixir, chart and Bazel suites for every touched target, plus
  `openspec validate enable-edge-record-pipeline-by-default --strict`.
