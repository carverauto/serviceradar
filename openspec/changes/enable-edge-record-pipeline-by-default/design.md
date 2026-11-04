# Design: Run the durable edge-record pipeline by default with a core-derived contract registry

## Context

As of `staging` on 2026-11-03:

- **Enablement.** The gateway reads `AGENT_GATEWAY_EDGE_RECORDS_ENABLED`, which
  defaults to `false`. Its `runtime.exs` still says the pipeline "must stay
  disabled outside a guarded vertical-slice target", although task 0.12 of
  `unify-sweep-results-proto` has closed. The chart sets that variable, the trust
  source `core`, and the registry only under `edgeRecords.enabled`. The same flag
  gates the core issuer key mount and the gateway's NATS publish permission for
  `telemetry.edge-record*.v1.bulk.>`. JetStream streams and sizing reservations
  for the edge-record streams are already unconditional.
- **Registry.** `ServiceRadar.Edge.ContractRegistryDocument` parses one JSON
  document from the environment, in both core and the gateway. Every value in it
  is supplied by the operator: `registry_epoch`, `registry_snapshot_sha256`, and
  `contract_bundle_sha256` per contract. No component checks any digest against
  contract content (`ServiceRadar.Edge.RecordValidate` checks only lengths).
  `ServiceRadar.Edge.ContractCatalog` already holds the authority model,
  projector, bounds and package identity of all six contracts.
  `OutputContract.current/1` joins the catalog entry with the registry entry.
- **Gateway admission.** `ServiceRadarAgentGateway.EdgeContractRegistry.admit/3`
  holds one snapshot. A record from an older epoch is admitted only while the
  held snapshot still registers its exact bundle; otherwise it is withheld as
  `:historical_bundle_not_registered`. A record from a newer epoch is withheld as
  `:registry_epoch_ahead`. Either withhold caps the lane's watermark until the
  registry changes back.
- **Delivery.** The gateway fetches `ServiceRadar.Edge.RecordTrust.snapshot/0`
  from a core node over ERTS every 5 seconds (`EdgeRecordTrustRefresh`). A
  snapshot expires 30 seconds after its request started. Agents receive standing
  grants in `AgentConfigResponse.edge_output_grants` and sweep leases through
  lease delivery. Each signed capability carries the full contract reference.
- **Issuer key.** `ServiceRadar.Edge.IssuerKey` loads a base64 seed from
  `SERVICERADAR_EDGE_ISSUER_KEY_FILE`. The chart's secret generator always
  creates `edge-issuer-seed`, but core mounts it only under
  `edgeRecords.enabled`. Core already has a precedent for a core-generated
  self-to-self signing seed: `ServiceRadar.Edge.ManagedCertificatePolicyKey`, an
  AshCloak-encrypted singleton row bootstrapped insert-only by
  `ComponentCertificateAuthority.ensure_policy_key/0`.
- **Operator switch.** `ServiceRadar.SweepJobs.LeaseSettings` resolves
  `leasing_enabled` from agent, then partition, then global rows, and defaults
  to off. Both `OutputGrants.config_grants/4` and `LeasePass` require it.
  Nothing in web-ng exposes it.
- **Agent.** `EdgeRecordSenderConfig` is optional (`nil` means no sender). It
  has one opt-in per producer family. Only the chart's bundled-agent
  `agent.json` renders it. Package and Ansible installs never render it.
- **Partition.** Migration `20261102231152_seed_default_partition` and
  `SchemaBootstrap` now seed `default` (#6270). An agent whose partition has no
  row gets no grant and no lease, and the only trace is a log warning.
- **serviceradar-control.** `TenantRuntimeValues` renders tenant chart values in
  code and does not mention `edgeRecords`. Hosted tenants therefore run with the
  pipeline off. The tenant cloak key is derived per tenant
  (`TenantSecrets.tenant_cloak_key/2`). The `serviceradar-secrets` Secret is
  produced by the chart's secret generator inside the tenant namespace.

## Goals / Non-Goals

- Goals:
  - A fresh install of any kind (Helm, hosted, Docker Compose, package-installed
    edge agent) carries agent telemetry on edge records with zero operator steps
    and zero settings rows.
  - Registry content and digests are a reproducible function of the release,
    and each epoch is signed by the issuer key (Decision 12).
  - Every condition that would leave an agent off the pipeline is visible before
    the cutover release ships (Decision 13).
  - An epoch change needs no operator action and never caps a lane.
  - No new Helm values. The one remaining product knob is a CNPG runtime setting
    with a code default.
- Non-Goals:
  - No legacy fallback. A producer that has migrated does not return to
    `StreamStatus` when the edge path is unhealthy. The legacy path is removed in
    the same release as this change (Decision 13), by
    `move-agent-telemetry-to-edge-records` tasks 8.1 and 8.2, except RTSP and
    live media.
  - The deterministic cost API, security revocation and Hello advertisement of
    `add-edge-contract-registry-lifecycle` stay in that change.
  - Issuer key rotation. The key id derivation already lets a verifier hold two
    keys side by side, and rotation can follow later.

## Decisions

### Decision 1: Always on, with no switch at any layer

The pipeline is the only agent data path, so turning it off means silently losing
telemetry. A switch would be a way to break an install, not to protect one.
Therefore:

- **Gateway.** The edge-record publisher and the core trust refresh always
  start. `AGENT_GATEWAY_EDGE_RECORDS_ENABLED` is deleted. Core is the only
  production trust source. The boot-time file source stays only as long as a test
  harness needs it, and no chart or Compose file renders it.
- **NATS.** The gateway's publish allow list always includes the three
  edge-record subjects.
- **Core.** The issuer key always exists (Decision 6). Standing grants are
  issued, and sweeps leased, for every agent whose partition resolves. Leasing
  still also requires `sweep_lease_plan_checks:v1` in Hello.
  `leasing_enabled` is dropped from the settings table, from `LeaseSettings`,
  `LeasePass` and `OutputGrants`. Its horizon fields stay.
- **Grant revocation.** Today the switch is the only thing besides a partition
  move that revokes a standing grant. Agent supersession
  (`Infrastructure.Agent` `:supersede`) and agent certificate revocation do not
  touch grants, so a stopped agent's grant stays in the trust snapshot until it
  expires. With the switch gone, `OutputGrants` revokes an agent's grants, moving
  their epochs, when its identity is superseded or its certificate is revoked. A
  partition move still reactivates the grant under a new epoch, as it does
  today.
- **Agent.** The sender and spool always run. `EdgeRecordSenderConfig.Enabled`
  and the four producer opt-ins are deleted. The spool directory defaults to
  `<runtime base>/edge-records`, which is `/var/lib/serviceradar/agent/edge-records`
  on Linux, matching the chart, Compose and package layouts. A producer emits
  edge records exactly when it holds the grant for its contract. That is already
  the gate in `move-agent-telemetry-to-edge-records` Decision 7, so the opt-ins
  were a second gate in front of it. An explicitly configured `spool_dir`,
  gateway address or security block is still honored, because it is local host
  layout and not a product knob.

Alternatives considered:

- Default the switch to on and keep it as a kill switch. Rejected: turning it off
  in the release after legacy removal loses data. A compromised or replaced agent
  is stopped by revoking its certificate or superseding its identity.
- Keep `edgeRecords.enabled` with a default of `true`. Rejected: control would
  still have to model it, and it adds nothing.

### Decision 2: Core derives the registry from the release catalog

The catalog is code reviewed with the release, and it is already what core signs
against and EventWriter projects with. A second, hand-typed copy can only
disagree with it. The registry therefore becomes a function of the catalog:

- **Bundle digest.** `contract_bundle_sha256` is SHA-256 over
  `ServiceRadar.Edge.HashGrammar` framing. The framing uses big-endian u64,
  length-framed strings and bytes, and presence markers. The fields are, in
  order:
  - the domain tag `serviceradar.edge.contract_bundle.v1` and digest version 1;
  - `contract_id` and `contract_version`;
  - the authority kind and `package_id` (presence-marked);
  - `route_profile`, `traffic_class` and `partition_rule`;
  - `cost_model_version`, `max_projected_rows` and `write_bytes_per_row`;
  - the payload message's full protobuf name;
  - the payload schema fingerprint;
  - `projection_revision`.
- **Schema fingerprint.** It is computed from the generated message definition,
  walked transitively in field-number order: each field's number, name, type,
  label and nested message name. It is not computed from `.proto` source text,
  so comments and formatting do not move it.
- **`projection_revision`.** A new positive integer on each catalog entry. It is
  strictly monotonic per `(contract_id, contract_version)`: any change to a
  bundle at the same `contract_version`, including a revert to earlier bytes,
  MUST bump it. Because the revision is hashed into the digest, a revert always
  produces a new digest, and no two revisions of one contract version share
  bytes. The revision orders bundles for the projection rule (Decision 4). It is
  also bumped by hand when projection semantics change without a wire or bound
  change. That one hand-maintained value is reviewed code, not deployment data.
- **Snapshot digest.** `registry_snapshot_sha256` is SHA-256 over the domain tag
  `serviceradar.edge.contract_registry.v1`, digest version 1, and the
  `(contract_id, contract_version, contract_bundle_sha256)` triples sorted by
  `(contract_id, contract_version)`.
- **What the digests omit.** The digests exclude the epoch number and every
  lifecycle state. Two installs, and every replica of one install, on the same
  release therefore compute the same snapshot digest.
- **Golden test.** A test pins every bundle digest and the snapshot digest of
  the current catalog. Changing the catalog fails it until the golden value is
  updated in the same commit, so an epoch change is always a reviewed decision.
  The golden file keeps an append-only history of `(projection_revision,
  bundle digest)` per `(contract_id, contract_version)`. The test fails if a
  bundle changes without a revision bump, if a revision ever decreases, or if a
  digest repeats in the history.
- **Compatibility rule.** A change that projectors cannot read alongside the old
  bundle MUST bump `contract_version`. A change that keeps the version MUST stay
  projectable by the new projector for records stamped with the old bundle, since
  those records drain on the new release (Decision 5).

The digest is computed only in Elixir. The agent never computes it: it copies the
reference from its signed capability. No cross-language golden test is needed.

Alternative considered: hash the `.proto` and Elixir source files at build time.
Rejected: comments and refactors would move the digest and force needless epochs.

### Decision 3: Gateways get the registry with the trust document; agents only see references

- **Gateway.** `RecordTrust.snapshot/0` gains a `"contract_registry"` member. It
  holds a format version (2) and every non-retired epoch: its number, state,
  snapshot digest, contract entries in the parser's existing entry shape extended
  with each entry's `projection_revision`, and the epoch's signature and signing
  key id (Decision 12). The gateway rebuilds the signed preimage, including each
  `projection_revision`, from these entries. The gateway verifies every
  epoch signature before it installs anything from the registry member, and it
  installs trust and the verified registry from the same core read. The member
  also carries the set of bundle digests that some live core node can project
  (Decision 4); the gateway refuses records outside it with a retryable refusal. A registry
  member that fails verification is refused whole: the gateway installs the new
  trust, keeps its previously verified registry, and surfaces the refusal
  (Decision 12). The registry is a few hundred bytes per epoch, so riding the
  existing 5-second refresh is free. The `Static` source and
  `AGENT_GATEWAY_EDGE_RECORD_CONTRACT_REGISTRY` are deleted. The gateway's next
  refresh call reports the snapshot digests it installed, and any signature
  refusal. That report is the readiness evidence for Decision 5.
- **Agent.** The agent receives no registry. Every grant and lease capability
  already carries the full contract reference, and the agent stamps exactly that
  reference. A new epoch reaches an agent as re-signed grants in its next
  config and re-issued leases (Decision 5). Agent config generation is
  invalidated at activation so the next poll returns the new grants.
- **Core and EventWriter.** They read the epoch table (Decision 4) through one
  cached reader, which verifies each row's signature on load (Decision 12). `OutputContract.current/1` returns the active epoch's entry.
  Validation and projection of a record use the entry of the epoch the record
  names.

Mixed versions during the upgrade itself: an old gateway may fail to install the
new document. That shows up as a withhold, never as a reject, and it clears once
the gateway rolls.

### Decision 4: Epochs are persisted in CNPG, move forward only, and start above every static label

A new table, `platform.edge_contract_registry_epochs`, holds one row per epoch:

- `epoch` (bigint, primary key) and `snapshot_sha256` (bytea);
- `document` (the canonical entry list, written once and never updated; each
  entry carries its `projection_revision`);
- `signature` (64 bytes) and `signing_key_id` (16 bytes), written once with the
  document (Decision 12);
- `state`, one of `candidate`, `active`, `draining` or `retired`;
- `created_at`, `activated_at`, `draining_since`, `drain_until` and `retired_at`;
- `last_matched_at`, the last time the coordinator saw a live core node whose
  catalog digest matches the epoch. It is set at insert and refreshed on each
  coordinator evaluation while such a node is live.

Partial unique indexes allow at most one `active` row and at most one
`candidate` row, and make `snapshot_sha256` unique among rows that are not
retired unactivated. An epoch is retired unactivated when it is `retired` with no
`activated_at`. Rows are insert-only, and only `state` and the timestamps change.

- **Numbering.** The first derived epoch is 1_000_000, and later ones are
  `max(epoch) + 1`. Static labels in use are small integers (1 and 2). Starting
  above them means "older than the floor" proves that a record came from the
  static era (Decision 7). It also keeps such a record from ever looking like it
  belongs to a newer derived epoch.
- **Booting with a new catalog.** A core node whose catalog digest matches no
  row inserts it as `candidate`. In the same transaction it retires any existing
  candidate unactivated, so a newer candidate supersedes an older one. The insert
  is idempotent through the digest index, so concurrent replicas converge on one
  row.
- **Booting with a superseded catalog.** A core node whose digest matches no
  `active` or `candidate` row is superseded: its catalog matches only a
  `draining` or `retired` row, or only an epoch retired unactivated. It keeps
  signing under the active epoch with that epoch's persisted, signature-verified
  document, exactly as a candidate-release node does (Decision 5 step 1), subject
  to the per-entry signing rule below. It never signs under its own catalog,
  never inserts or claims a candidate, and never counts toward activation
  readiness. It projects records under the projection rule below. A downgrade
  therefore never moves the active epoch backward.
- **Per-entry signing rule.** Every core node, whatever its catalog, signs a
  grant, lease or delivery grant under the active epoch only for contract entries
  whose exact bundle digest its own catalog holds, so a node never authorizes
  production of records it cannot project. A delivery grant for a draining-epoch
  backlog record is the exception: it follows the projection rule, not the
  exact-digest rule, so a forward upgrade's backlog can still be delivered.
  Entries it does not hold get no new signatures from that node. Their existing
  grants run to expiry unless no live core node can project the bundle, in which
  case core revokes them (below). Producers back-pressure as they do without a
  grant. Signing is keyed on the exact bundle; projection is not.
- **Projection rule.** A core node can project a record when its catalog holds
  an entry with the record's `contract_id` and `contract_version` whose
  `projection_revision` is greater than or equal to the record's bundle
  revision. The record's bundle revision is read from the entry of the epoch the
  record names. This is the direction Decision 2's compatibility rule
  guarantees: a new projector reads old bundles of the same version, and an old
  projector is never assumed to read a newer one. Because revisions are strictly
  monotonic, a revert never makes a newer node look older than its records.
- **Records no live core can project.** When core finds a bundle that no live
  core node can project under the projection rule, it holds that bundle's
  records at three layers.
  1. *Production stops.* Core revokes the grants and leases for that bundle,
     with the revocation authority it already uses for superseded agents.
  2. *Admission stops.* Core publishes the set of projectable bundles with the
     trust and registry delivery (Decision 3). A gateway refuses a record whose
     bundle is outside that set with a retryable refusal, never a rejection.
     The agent keeps the record in its durable, byte-bounded spool and
     back-pressures, as it does without a grant.
  3. *Stream backlog moves to the dead-letter stream.* A record already in
     `TELEMETRY_EDGE_RECORD_V1_BULK` that EventWriter cannot project is
     published, with its original bytes, to the existing generic dead-letter
     stream `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` (#6295) under the reason
     `awaiting_roll_forward`, and then acknowledged on the bulk stream. When a
     node that can project it returns, it is redriven through the ingest
     ledger, so a redrive is idempotent.

  The bound is honest, not absolute. Only records admitted between the
  rollback and the gateways' next projectable-set refresh (about one 5-second
  trust refresh), plus anything admitted ahead of revocation, reach the bulk
  stream. They are preserved up to the free capacity of
  `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`, which is `DiscardNew` with `MaxAge`
  disabled and is shared with genuine poison records: 64 MiB by default, 32 MiB
  on `small` and 4 MiB on `tenant-2g` (docs/edge-record-dead-letter-runbook.md).
  When the full dead-letter stream refuses a record's copy, EventWriter
  acknowledges the bulk delivery and records the loss; it never NAKs the record
  or leaves it unacknowledged, so overflow cannot occupy the durable's
  `max_ack_pending` slots or stall other contracts' projection. The loss is
  counted once per distinct record, keyed by `Sr-Edge-Delivery-Id`, per contract
  and bundle; it raises a managed alert and shows in pipeline status as
  `awaiting_roll_forward_overflow`, so it is never silent. After the refresh window
  the agent spools hold everything, bounded by the agent spool budget, so no
  loss is possible past the window. Pipeline status shows `awaiting_roll_forward`
  counts for the spool refusals and the dead-lettered records. No record is
  rejected because of a digest mismatch alone.
- **Redeploying an abandoned catalog.** The one exception: a node whose digest
  matches only an epoch retired unactivated, while no candidate exists, inserts
  its catalog as a new candidate under a new epoch number, so redeploying a
  release after its candidate was abandoned works. Until that candidate
  activates, the node signs under the active epoch by the per-entry signing rule.
  While another candidate
  exists, nodes left over from a superseded release cannot take the candidate
  back from the newer one.
- **Signing nothing.** A core node signs nothing only when no active epoch
  document verifies (Decision 12).
- **Abandoned candidates.** The coordinator retires a candidate unactivated once
  `last_matched_at` is older than a full capability-lifetime window: the 8-day
  standing-grant window plus its 5-minute lead. Because the time is persisted,
  coordinator failover and pod restarts do not reset the window. This covers a
  release that was rolled back before its epoch activated.
- **Retired unactivated.** Such an epoch never signed anything and never signs
  anything. Core drops it from the trust document, so gateways drop it too. A
  record naming it is rejected as `registry_epoch_retired`.
- **First epoch.** With no `active` row, which is every fresh install and every
  upgrade from the static registry, the first candidate activates at once. No
  epoch exists for it to drain.

Alternative considered: derive the epoch number from the digest or the release
version. Rejected: the gateway orders epochs, and a digest has no order. A
release version can repeat a catalog, or change without changing it.

### Decision 5: Epoch transition protocol, run by core

The coordinator singleton (`ServiceRadar.Cluster.CoordinatorManager`) runs the
transition:

1. **Candidate.** A new release's core inserts epoch `n+1` as `candidate` on
   boot, retiring any older candidate unactivated (Decision 4). Gateways receive
   it in the next trust document alongside active `n`. Core keeps signing under
   `n`, using `n`'s persisted document rather than its own catalog, so its
   signatures match what it advertises. It signs only entries whose exact bundle
   digest its catalog holds (Decision 4, per-entry signing rule). Readiness is
   only ever evaluated for the one candidate.
2. **Readiness.** Activation requires two facts, read fresh on each evaluation:
   - Every live core node reports the candidate digest as its catalog digest.
     A live core node is a connected node running the core application.
   - Every live gateway has reported installing a document that contains the
     candidate. A live gateway is one `ServiceRadar.GatewayTracker` lists with a
     heartbeat within its window.

   Activation is never forced on a timeout. While readiness is incomplete, the
   pipeline status names the epoch and each component that does not hold it.
   If the release is rolled back before activation, no live core node matches
   the candidate any more. After a full capability-lifetime window the
   coordinator retires it unactivated (Decision 4), and `n` stays active
   throughout.
3. **Activation.** One transaction sets `n+1` `active` and `n` `draining`, with
   `drain_until` computed as below. On commit:
   - Agent configs are invalidated, so grants are re-signed under `n+1`.
   - `LeasePass` supersedes every slot leased under `n` that has not started,
     and re-leases it under `n+1`. A slot that has started finishes under `n`,
     because runs are sticky (`add-edge-contract-registry-lifecycle`, "Output
     contract and format are sticky per producer run").
4. **Draining.** The gateway holds `n` and admits a record under it against
   `n`'s exact entry. This replaces today's rule, which looked the record up in
   the current snapshot. EventWriter validates it with `n`'s entry and projects
   it on a node that can project it (Decision 4, projection rule). After a
   forward upgrade that changed a bundle at the same `contract_version`, every
   node on the new release qualifies, so the backlog drains normally. Core issues
   no new production capability under `n`. A delivery grant for an `n` backlog
   record is still issued while `n` drains, by a node that can project it.
5. **Retirement.** At `drain_until`, `n` moves to `retired`.
   - `drain_until` is `activated_at(n+1)` plus the longest lifetime of any
     capability core could have signed under `n`. That is the larger of the
     8-day standing-grant window plus its 5-minute lead and the longest started
     slot's collection window.
   - The maximum delivery-grant lifetime is then added on top.

   After retirement, a record naming `n` cannot hold a valid capability, so the
   gateway rejects it permanently as `:registry_epoch_retired` and counts it.

Why re-lease at activation: without it, a 30-day lease horizon keeps `n`
producing records for a month and the drain horizon grows to match. Re-leasing
bounds new production under `n` to slots that have already started.

Why core drives readiness instead of an agent cohort: agents never hold the
registry. An agent is "ready" for `n+1` the moment it holds a capability signed
under `n+1`, and it can only get one after activation.

Fleet-wide effect: every epoch change re-signs every agent's grants. The configs
of the whole fleet therefore change once per catalog change. That is one config
push per release that changes a contract, which is acceptable.

### Decision 6: Core generates the issuer key and stores it in CNPG

- **Storage.** A new singleton resource, `ServiceRadar.Edge.EdgeIssuerKeyRecord`,
  backs the table `platform.edge_issuer_key` (the check `id = 'default'`
  enforces one row). It mirrors `ManagedCertificatePolicyKey`: the `public_key`
  is plaintext, and the `seed` is AshCloak-encrypted with
  `decrypt_by_default []`.
- **Bootstrap.** Bootstrap is insert-only. The first caller generates 32 random
  bytes, inserts with `upsert_fields []`, and re-reads the persisted winner.
  Concurrent replicas therefore converge on one key, and a restart never changes
  it.
- **Read path.** `IssuerKey.configured/0` becomes an ensure-then-cache read.
  The `{:error, :not_configured}` branch, the file loader, the env reads in both
  `runtime.exs` files, the chart volume, and `edge-issuer-seed` in the secret
  generator's `REQUIRED_KEYS` and patch list are all deleted.

Rationale:

- It is self-to-self material, so AGENTS.md allows either a Kubernetes Secret or
  this pattern. CNPG wins on three counts:
  - Docker Compose and every non-Helm install get the key with no new mechanism.
  - `secrets.autoGenerate=false` no longer needs an operator-supplied seed.
  - The key travels with the database backup.
- That last point matters for hosted tenants. A tenant restore restores CNPG,
  and the tenant cloak key is derived deterministically, so the restored core
  keeps the same issuer key and outstanding grants stay valid. With a
  Secret-held seed, a restore into a fresh namespace would run the secret
  generator again. It would silently mint a new key and strand every spooled
  record.
- The seed is never in `RecordTrust` output. The gateway still receives only
  `trust_entry/1`.
- The same key signs each registry epoch (Decision 12), so a registry and the
  capabilities stamped against it share one trust anchor.

Upgrade: core imports the existing file seed. On the first boot that finds no
stored key, core reads `SERVICERADAR_EDGE_ISSUER_KEY_FILE` once, stores that seed
encrypted in the singleton row, and logs the import. It generates a seed only when
no file is configured, which is every fresh install. Once a key is stored the file
is never read again. A configured file that is not a private, well-formed seed
stores nothing, so core never replaces a real key with a random one.

Key continuity matters because the registry epochs are signed with the issuer key
(Decision 12) and verified on every load. An installation that ran a release
signing epochs, grants or leases with the file key would otherwise fail every
verification after the switch, and core would sign nothing. (Revised 2026-11-04
at track A's request; this replaces "core does not import the existing file
seed".)

The import needs the file mounted on the first cutover boot. The chart therefore
keeps the `edge-issuer-seed` mount and `SERVICERADAR_EDGE_ISSUER_KEY_FILE` for the
cutover release on installs where the Secret key exists. The release after it
removes the mount, the env var and the import, together with the secret
generator's key.

### Decision 7: Static-era records are rejected and counted, never withheld

A record whose `registry_epoch` is below the derived floor, 1_000_000, was
stamped against a hand-written document. No component can now prove its bundle
digest means anything. The gateway resolves such a record as a permanent
rejection, `:static_registry_epoch`, and the agent quarantines it as it does any
other rejection. That classification runs before capability-signature
verification, so an old-key signature cannot turn it into a withhold. A withhold
here would cap the lane forever, which is the failure this change removes.

The rule is permanent and costs one comparison. It is a statement about which
epochs can exist, not compatibility code for a legacy path, and no later release
has to delete it.

### Decision 8: Partition bootstrap and visible blockers

- **Bootstrap.** The `default` partition seed in the migration and in
  `SchemaBootstrap` (#6270) is the bootstrap, and this change gives it a
  requirement. Together with Decisions 1, 4 and 6, a fresh install needs no rows
  beyond what bootstrap writes:
  - the key is generated on first use;
  - the first epoch activates at once;
  - leasing and grants have no switch.
- **Visible blockers.** Core records a per-agent edge pipeline condition with a
  reason, exposed in the agent's API representation and in web-ng's agent
  detail. A healthy agent shows none. The blocking reasons are:
  - `partition_not_found` (the agent's partition slug has no row);
  - `no_live_gateway_on_active_epoch`;
  - `spool_unavailable`, which the agent reports in its status when its spool
    cannot be opened.

  A log warning alone is not enough. The fresh-install defect sat for weeks
  behind a warning whose reason the default formatter did not print.
- **Before the cutover release.** Because the cutover release has no legacy path
  (Decision 13), these reasons must be visible on an install before it upgrades,
  not after. Decision 13 covers the read-only readiness report that ships ahead
  of the cutover release.
- **No auto-created partitions.** Core does not create a partition from an
  agent-reported slug. A partition is a network-scope trust boundary, and letting
  an agent's claim create a scope would let any agent mint one.

### Decision 9: The one remaining knob is a scoped runtime setting

The spool byte budget varies by host disk, so it stays a knob.

- **Storage.** The table `platform.sweep_lease_settings` is renamed
  `platform.edge_pipeline_settings`, keeping its global, partition and agent
  scopes. It loses `leasing_enabled`, keeps `horizon_seconds` and
  `max_horizon_seconds`, and gains `spool_max_bytes`.
- **Resolution.** Each field resolves agent, then partition, then global, then
  the code default. The default is 1 GiB, which every chart-deployed agent
  already runs, up from today's 256 MiB Go default.
- **Delivery.** The resolved value is delivered in `AgentConfigResponse`. The
  agent applies it at admission, so a lower budget only blocks new appends until
  the spool drains below it.
- **Helm.** `edgeRecords.maxSpoolBytes` is not replaced by any Helm value.

### Decision 10: Upgrade path is a clean switch

- **Chart.** `_helpers.tpl` fails the render when `.Values.edgeRecords` has any
  key. The message is:

  ```text
  edgeRecords was removed in <version>: the durable edge-record pipeline is
  always on and core derives its contract registry. Delete the edgeRecords block
  from your values. See docs/docs/data-pipeline.md, "Upgrading from the static
  registry".
  ```

  `values.yaml` no longer has the block, so an untouched install never trips the
  check.
- **farm01.** It is not Argo-managed, so the operator who rolls farm01 deletes
  `edgeRecords` from its values when it takes the release candidate for the M4.1
  gate (Decision 13). Drain is optional. To lose no static-era backlog, turn
  leasing off while still on the old release, wait for the spool depth to reach
  zero, then upgrade. Without the drain, any undelivered static-era records are
  rejected and counted (Decision 7). Either way, lanes keep moving.
- **demo.** Delete `edgeRecords` from the gitops values in the same commit that
  bumps the chart. No drain, because demo is disposable.
- **Hosted tenants and Docker Compose.** No values change, because neither
  ever set `edgeRecords`. They move onto the pipeline on upgrade.
- **Rollback.** Rolling back to a static-registry release needs `edgeRecords`
  values again. Records spooled under derived epochs would then be withheld as
  `:registry_epoch_ahead` until the install rolls forward again. The same
  release removes the legacy path, so a rollback is also a rollback across the
  legacy removal. Rollback across this release is therefore unsupported.

### Decision 11: Relationship to other pending changes

- **`add-edge-contract-registry-lifecycle`.** This change takes over:
  - the registry source;
  - the candidate, active, draining and retired lifecycle, with each epoch
    signed by the issuer key;
  - readiness and the atomic switch;
  - drain under the exact bundle, and stale-component fencing.

  It also re-scopes that change's tasks 1.1, 1.5, 1.6 (the readiness and epoch
  parts) and 1.7. That change keeps the deterministic cost API (1.2), security
  revocation, Hello advertisement (1.3) and the `projection` task (1.4). Its
  ADDED requirement "Output contract bundles have a governed deployment
  lifecycle" keeps its "signed" wording, which Decision 12 now delivers. This
  change amends that requirement in place: it has no `ready` state, readiness
  comes from every live core node and gateway, and agents never hold the
  registry (Decision 5). Its tasks 1.1, 1.5, 1.6 and 1.7 record the re-scope.
- **`move-agent-telemetry-to-edge-records`.** Its pending requirement
  "Agent-scheduled producers emit under standing output grants" made grants
  depend on the operator switch. This change amends it in place: a grant is
  issued while the contract is active in the active registry epoch and the
  agent's partition resolves. It is revoked by moving its epoch when the agent's
  identity is superseded or its certificate is revoked, and reactivated under a
  new epoch when the agent moves to another partition. Its Decision 2 notes the
  change. Its "signed contract registry" wording stays. Its task 8.1 (legacy
  removal) and task 8.2 ship in the same release as this change (Decision 13).
- **`unify-sweep-results-proto`.** None of its pending deltas mentions the
  Helm registry or the switch, so there is no conflict.

### Decision 12: Each registry epoch is signed by the issuer key

Core signs each epoch once, when it inserts the candidate row, with the edge
issuer key (Decision 6).

- **What is signed.** Ed25519 over these bytes, in `HashGrammar` framing:
  - the domain tag `serviceradar.edge.contract_registry_epoch.v1` and signature
    format version 1;
  - the epoch number (u64);
  - the snapshot digest (32 bytes);
  - the contract count (u64), then for each contract, sorted by
    `(contract_id, contract_version)`: the contract id, the contract version, the
    bundle digest, the admission fields the gateway acts on (route profile,
    traffic class, partition rule and cost model version), and the
    `projection_revision`.

  The signature binds the epoch number, the snapshot digest and every bundle
  digest. The admission fields are signed as well, because the gateway routes
  and charges from them and could not otherwise detect a changed route on a
  correctly signed bundle digest. The `projection_revision` is signed because
  the projection rule (Decision 4) compares it for records whose exact bundle a
  node does not hold, and a reader cannot recover it from the digest.
- **What is not signed.** The lifecycle state (`candidate`, `active`, `draining`,
  `retired`) changes after signing, so it is not covered. It comes only from core
  over the authenticated ERTS refresh. A gateway admits records only under epochs
  whose signed document it has verified, whatever their state.
- **Storage.** The signature and the signing key id are written into the epoch
  row with the document and never change.
- **Verification on every load.** Any copy of an epoch that is read from outside
  the memory of the process that verified it is verified again before use. That
  covers the CNPG row when core's reader loads it, the trust document when the
  gateway receives it, and any persisted or `:persistent_term` cache on either
  side. The verifying key is the issuer public key whose key id the epoch names,
  from the trust entries core publishes. In-memory structures built from a
  verified load are used as-is.
- **Core on a bad signature.** Core excludes the row from its reader, signs
  nothing under it, and reports `registry_epoch_signature_invalid` with the epoch
  in pipeline status. If the active epoch fails verification, core issues no new
  capability at all until it is resolved. Someone with CNPG write access but
  without the cloak key cannot forge registry contents core will use. Because the
  lifecycle state is unsigned, such a writer can still change which correctly
  signed epoch is `active`, replaying an older registry, or mark epochs `retired`
  so that gateways reject their records. The signature protects contents, not
  the lifecycle.
- **Gateway on a bad signature.** The gateway refuses the whole registry member
  of that document. It installs nothing from it, keeps its previously verified
  registry, and still installs the document's trust. It surfaces the refusal
  three ways:
  - an error log naming the epoch and key id;
  - the `edge_registry_signature_rejected` counter;
  - its next refresh report, which core shows in pipeline status naming the
    gateway.

  Such a gateway never counts as holding a candidate, so activation waits. A
  gateway with no previously verified registry withholds every record as
  `registry_unavailable`, the same as before it first loaded one.

Rationale: the signature binds the registry to the key that signs every
capability stamped against it. It also stops a database-only write or a tampered
cache from changing the contents of any epoch core signs against or a gateway
admits under. It does not stop a database-only write from moving lifecycle state
between correctly signed epochs, and it does not defend against a compromised
core, which holds the key anyway.

### Decision 13: Default-on and the legacy removal ship in one release

The release that carries this change, the cutover release, also carries
`move-agent-telemetry-to-edge-records` tasks 8.1 and 8.2. Those remove every
legacy agent emission on `StreamStatus` and `PushStatus` and the gateway
publishers that serve them, except RTSP and live media. Every family soak that
task 8.1 depends on (tasks 2 to 7 of that change) must pass before the release
is cut.

- **Every agent gets the sender in the same release.** The default-on sender
  is in the Go agent itself (Decision 1), so package-installed and
  Ansible-installed agents get it from the agent build, with no config change.
  The packages and the `serviceradar-ansible` role must create the runtime
  directory (`/var/lib/serviceradar/agent` on Linux, the platform runtime base
  elsewhere), writable by the agent user. The release verifies this for every
  published agent platform.
- **The farm01 M4.1 run is a pre-release gate.** The release candidate,
  including the legacy removal, runs on every farm01 agent for 7 days, with
  tracking evidence, before the release is cut. A failure blocks the release
  and does not reintroduce a fallback.
- **Blocking reasons are visible before the release.** A read-only edge
  pipeline readiness report ships in a release ahead of the cutover release. It
  changes no behavior and depends on nothing else in this change. It lists every
  agent that would be off the pipeline after the upgrade, with the reason:
  - `partition_not_found`;
  - `agent_upgrade_blocked`: the agent release rollout cannot deliver the
    cutover agent build, because the agent is pinned, its rollout is paused, or
    no artifact exists for its platform;
  - `agent_disconnected`: the agent has not connected within the agent
    tracker's window.

  After the upgrade, the same reasons, plus `agent_upgrade_pending`,
  `no_live_gateway_on_active_epoch` and `spool_unavailable`, become the per-agent
  conditions of Decision 8. A package agent's spool health can only be known
  once it runs the cutover build. That is why the packages and the role create
  the directory, and why farm01's package agents are part of the gate.
- **Hosted tenants.** Control reads the report before upgrading a tenant and
  starts the agent rollout at core upgrade (see "serviceradar-control").

Alternative considered and rejected by the product owner: default-on in one
release and legacy removal in the next. That keeps a fallback for one release,
which is legacy support this product does not build.

## Risks / Trade-offs

- **One release is the whole cutover, with no fallback.** On upgrade every
  install moves every producer onto edge records, and the status path is gone. An
  agent that cannot reach the pipeline loses telemetry until it is fixed.
  Mitigation: the farm01 M4.1 run is a pre-release gate, the readiness report
  ships ahead of the release, and control holds back tenants with blocking
  reasons (Decision 13).
- **Agents upgrade after core.** Between the core and gateway upgrade and an
  agent's own upgrade, an agent build without the default-on sender sends
  nothing the new gateway accepts. Mitigation: the release rollout targets every
  agent at core upgrade, and the readiness report flags agents that the rollout
  cannot reach before the release ships. During the window the agent shows
  `agent_upgrade_pending`.
- **A bad registry signature freezes a gateway's registry.** A gateway that
  refuses a document keeps its previous registry. A candidate it never verifies
  blocks activation, which is the intended fail-closed behavior and is visible in
  pipeline status.
- **Readiness can stall.** One unreachable gateway still listed live blocks
  activation, while core keeps signing under the old epoch. Data keeps flowing,
  the stall is visible in pipeline status, and gateway liveness ages out on the
  tracker's heartbeat window.
- **Fleet-wide config churn per epoch.** It is bounded to one push per
  contract-changing release (Decision 5).
- **`projection_revision` is hand-bumped.** A missed bump hides a semantic change
  behind an unchanged digest. Mitigation: the projector tests that pin row output
  sit next to the golden digest test, and review covers both.
- **Static-era backlog is rejected on installs that skip the drain.** That is
  bounded to farm01 and demo, and the loss is counted rather than silent.

## Migration Plan

1. Land core: epoch table, issuer key table, the settings rename and
   `leasing_enabled` drop, catalog derivation and the golden test, the trust
   document extension, the transition coordinator, and pipeline conditions.
2. Land the gateway: multi-epoch admission from the trust document, the
   static-era rejection, removal of the `Static` source and the enable variable,
   and a default core trust source.
3. Land the agent: sender always on, default spool directory, producer opt-ins
   removed, budget from config.
4. Land the chart in the same release: remove `edgeRecords`, add the fail guard,
   remove the issuer mount and seed key, make the NATS permissions
   unconditional, update the README and tests.
5. Ahead of the cutover release, ship the read-only readiness report
   (Decision 13) and let every install see its blocking reasons.
6. Run the release candidate, with the legacy removal included, on all farm01
   agents for 7 days (M4.1). Cut the release only after that gate passes.
7. Roll demo, then the hosted fleet through serviceradar-control.

## serviceradar-control

What control has to change. No change adds a value, because there is no
`edgeRecords` value left to model.

1. Reject `edgeRecords` in the rendered tenant values, including anything merged
   from `CONTROL_PLANE_TENANT_CHART_VALUES_JSON`, so a hosted override fails in
   control with a clear error rather than at chart render.
2. Plan the one-release jump. The default-on chart is also the chart that
   removes the legacy status path, so a tenant goes straight from no pipeline to
   no legacy. Before upgrading a tenant, control reads the tenant's readiness
   report (Decision 13). It does not upgrade automatically while any agent has a
   blocking reason, until the tenant operator acknowledges it. It starts the
   tenant's agent release rollout as soon as core and the gateway are upgraded.
   Record the cutover chart version in `TenantChartCapabilities` or the chart
   contract versions.
3. Restore. The issuer key and registry epochs now live in CNPG, encrypted with
   the tenant cloak key. Confirm that the restore execution plan restores CNPG
   together with a cloak key equal to the original, which the per-tenant
   derivation should already guarantee. Confirm too that nothing depends on the
   `edge-issuer-seed` Secret key.
4. Health. Add a tenant runtime health check for edge pipeline readiness: an
   active registry epoch, the issuer key present, and every live gateway holding
   the active epoch. It reads from core's health endpoint once that exists
   (task 1.8).
5. Verify, with no change expected: JetStream sizing already reserves the four
   edge-record streams in chart profiles. `agent.runtimeStorage` stays enabled
   in hosted values. The agent's edge-record lane uses the existing gateway gRPC
   port, so tenant network policy needs no new rule.

### Draft issue for carverauto/serviceradar-control (not filed)

```text
Title: Hosted tenants: guard removed edgeRecords values and gate on the default-on edge pipeline chart

ServiceRadar is making the durable edge-record pipeline always on, with a
core-derived, issuer-signed contract registry (carverauto/serviceradar#6288,
OpenSpec change enable-edge-record-pipeline-by-default). The chart's edgeRecords
values block is removed, and the chart fails to render when any edgeRecords key
is set. Control never rendered edgeRecords, so hosted tenants have been running
with the pipeline off.

The same release removes the legacy agent status path (everything except
RTSP/live media). A hosted tenant therefore jumps in one upgrade from "pipeline
off, legacy on" to "pipeline on, no legacy". Any tenant agent that cannot reach
the pipeline loses telemetry from that upgrade until it is fixed.

Needed in control:

1. Reject edgeRecords in rendered tenant values, including anything merged from
   CONTROL_PLANE_TENANT_CHART_VALUES_JSON, with a clear error before Helm runs.
2. Plan the one-release jump. Before upgrading a tenant to the cutover chart,
   read the tenant's edge pipeline readiness report (shipped by ServiceRadar
   ahead of the cutover release). Do not upgrade automatically while any agent
   has a blocking reason, such as a partition with no row or an agent the
   release rollout cannot reach, until the tenant operator acknowledges it.
   Start the tenant's agent release rollout as soon as core and the gateway are
   upgraded, because an agent on an older build sends nothing the new gateway
   accepts. Record the cutover chart version in the tenant chart
   capability/contract gating.
3. Restore: the edge issuer key and the registry epochs now live in tenant CNPG,
   encrypted with the tenant cloak key. Confirm the restore plan restores CNPG
   with the same cloak key, and that nothing depends on the edge-issuer-seed key
   of serviceradar-secrets (it is no longer generated).
4. Add a tenant runtime health check for edge pipeline readiness once core
   exposes it: an active registry epoch, the issuer key present, and every live
   gateway holding the active epoch.
5. Verify, no change expected: the JetStream profile reservations for the four
   edge-record streams, agent.runtimeStorage stays enabled, and the gateway
   gRPC port already carries the edge-record lane.

No new chart values are involved; nothing about the pipeline is configured per
tenant.
```

## Resolved Questions

The product owner answered these on 2026-11-03.

1. **Per-agent off switch.** Removed (Decision 1). Supersession and certificate
   revocation revoke grants instead.
2. **Static-era backlog at the switch.** It is rejected and counted, with an
   optional farm01 drain (Decisions 7 and 10).
3. **Registry signing.** Each epoch is signed with the issuer key, and gateways
   and core verify it on every load (Decision 12). The "signed contract
   registry" wording in `move-agent-telemetry-to-edge-records` and
   `add-edge-contract-registry-lifecycle` stays.
4. **Release order.** Default-on and the legacy status-path removal ship in one
   release (Decision 13).
