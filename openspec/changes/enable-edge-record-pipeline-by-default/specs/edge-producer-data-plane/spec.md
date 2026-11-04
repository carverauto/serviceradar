# edge-producer-data-plane Delta

## ADDED Requirements

### Requirement: The durable edge-record pipeline is always on
The durable edge-record pipeline SHALL run on every installation with no on/off
switch in Helm values, process environment, or CNPG settings. Core SHALL issue
standing grants and lease sweeps to every agent whose partition resolves, with
leasing additionally requiring the agent's advertised lease capability. The agent
gateway SHALL always admit and publish edge records and refresh trust from core.
The agent SHALL always run its spool and sender. A producer SHALL emit edge records
exactly when the agent holds the grant for its contract; it SHALL NOT need a
separate local opt-in. Core SHALL revoke an agent's standing grants, moving their
epochs, when the agent's identity is superseded or its certificate is revoked.

#### Scenario: A fresh installation carries telemetry with no settings rows
- **GIVEN** a fresh installation with no edge pipeline settings rows and no
  pipeline-related Helm values
- **WHEN** an agent in the `default` partition connects and collects metrics
- **THEN** core issues it standing grants for every active standing-grant contract
- **AND** its metrics arrive as edge records and are projected

#### Scenario: A package-installed edge agent has no sender block
- **GIVEN** an edge agent whose local config has no `edge_record_sender` block
- **WHEN** it starts
- **THEN** it opens its spool under its runtime base path and runs the sender
  against its configured gateway

#### Scenario: A superseded agent's grants are revoked
- **GIVEN** an agent holding standing grants
- **WHEN** its identity is superseded by another agent on the same device
- **THEN** core moves the epoch of each of its grants
- **AND** the gateway's next trust document fences records signed before the
  supersession

#### Scenario: No switch can turn the pipeline off
- **WHEN** an operator looks for a value, variable, or setting that disables the
  edge-record pipeline for an installation, partition, or agent
- **THEN** none exists
- **AND** superseding an agent's identity or revoking its certificate remains
  the way to stop its production, and moves its grant epochs

### Requirement: Core derives the output-contract registry from the release catalog
Core SHALL derive every output-contract bundle digest and the registry snapshot
digest from `ServiceRadar.Edge.ContractCatalog` alone, and SHALL NOT read any part
of the registry from deployment configuration. A bundle digest SHALL be SHA-256
over domain-separated, length-framed fields in the `ServiceRadar.Edge.HashGrammar`
framing. The fields are:

- the contract id and version;
- the authority kind and package id;
- the route profile, traffic class, and partition rule;
- the cost model version and per-record bounds;
- the payload message name;
- a schema fingerprint computed from the generated message definition, not from
  source text;
- a catalog `projection_revision`.

The snapshot digest SHALL cover the sorted `(contract_id, contract_version,
contract_bundle_sha256)` triples, and SHALL exclude the epoch number and every
lifecycle state. Every core replica and every installation on one release SHALL
therefore compute the same digests. A golden test SHALL pin them. A change that
the new projector cannot read alongside the old bundle SHALL bump
`contract_version`.

#### Scenario: Two installations on one release agree
- **GIVEN** two installations running the same release
- **WHEN** each core computes its registry
- **THEN** both compute the same bundle digests and the same snapshot digest
- **AND** their epoch numbers MAY differ

#### Scenario: A catalog change is a reviewed decision
- **WHEN** a commit changes a catalog entry's bounds, route, cost model, payload
  schema, or projection revision
- **THEN** the golden digest test fails until the commit updates the pinned
  digests

#### Scenario: A comment in a proto file does not move the digest
- **WHEN** only comments or formatting change in a contract's `.proto` file
- **THEN** the schema fingerprint and the bundle digest are unchanged

### Requirement: Registry epochs are persisted and only move forward
Core SHALL persist each derived registry snapshot as one epoch row in CNPG, write
its document once, and allow at most one `active` epoch and at most one
non-retired `candidate` epoch. Epochs SHALL be numbered from 1_000_000 upward, and
each new epoch SHALL be one more than the highest existing epoch. A core node
whose catalog digest matches no epoch SHALL insert it as `candidate`, and in the
same transaction SHALL retire any existing candidate without activating it.
Concurrent inserts SHALL converge on one row. A core node whose catalog digest
matches no `active` or `candidate` epoch SHALL keep signing production
capabilities, leases, and delivery grants under the active epoch using that
epoch's persisted, signature-verified document. Every core node SHALL sign under
the active epoch only for contract entries whose exact bundle digest its own
catalog holds; it SHALL give entries it does not hold no new signatures, and their
existing grants SHALL run to expiry. A core node SHALL be able to project a
record when its catalog holds an entry with the record's contract id and contract
version whose bundle was introduced in the same epoch as the record's bundle or a
later one, where a bundle's introducing epoch is the lowest-numbered epoch whose
document lists its digest. A record that no live core node can project SHALL be
held durably and SHALL NOT be acknowledged, dropped or rejected; it SHALL be
counted, reported as awaiting roll-forward in pipeline status, and drained when a
node that can project it returns. No record SHALL be acknowledged, dropped or
rejected because of a bundle digest mismatch alone. A superseded core node SHALL
NOT sign under its own catalog, insert or claim a candidate, count toward activation readiness, or
change the active epoch. The one exception is a core node whose digest matches
only an epoch retired without activation while no candidate exists: it SHALL
insert its catalog as a new candidate under a new epoch number. A core node SHALL
sign nothing only when no active epoch document verifies. Core SHALL persist, per
epoch, the last time a live core node's catalog digest matched it, refreshing it
while such a node is live. Core SHALL retire a candidate without activating it
once that time is older than a full capability-lifetime window. An epoch retired without activation SHALL never sign
anything, SHALL be dropped from the registry core sends to gateways, and a record
naming it SHALL be rejected as `registry_epoch_retired`. When no `active` epoch
exists, core SHALL activate the first candidate immediately.

#### Scenario: Replicas of a new release boot together
- **WHEN** three core replicas of a release with a new catalog start at once
- **THEN** exactly one `candidate` epoch row exists for that snapshot digest

#### Scenario: A rolled-back core node signs only under the active epoch
- **GIVEN** epoch 1_000_002 is active and 1_000_001 is draining
- **WHEN** every core node is rolled back to a catalog matching 1_000_001
- **THEN** grants and leases keep being signed under 1_000_002's persisted document
  for every entry whose bundle digest the rolled-back catalog holds
- **AND** no capability is signed under 1_000_001
- **AND** the active epoch remains 1_000_002

#### Scenario: The whole fleet is rolled back after a contract version bump
- **GIVEN** epoch 1_000_002 is active and bumped one contract's version over
  draining 1_000_001
- **AND** agents hold grants and have records in flight under the bumped bundle
- **WHEN** every core node is rolled back to a catalog matching 1_000_001
- **THEN** no core node signs a new grant, lease or delivery grant for the bumped
  entry, and its existing grants run to expiry while producers back-pressure
- **AND** entries whose bundle digest is unchanged keep being signed under 1_000_002
- **AND** in-flight records under the bumped bundle are held durably, counted and
  reported as awaiting roll-forward, never dropped or rejected
- **AND** they drain once a core node that can project them returns

#### Scenario: A rollback past a superseded candidate keeps signing
- **GIVEN** epoch 1_000_000 is active
- **AND** release B inserted candidate 1_000_001
- **AND** release C then inserted candidate 1_000_002, retiring 1_000_001 unactivated
- **WHEN** every core node is rolled back to release B
- **THEN** grants, leases and delivery grants keep flowing under 1_000_000 for
  every entry whose bundle digest release B's catalog holds
- **AND** no B node inserts or claims a candidate while 1_000_002 exists
- **AND** 1_000_002 is not activated

#### Scenario: The abandonment window survives a coordinator failover
- **GIVEN** a candidate that no live core node has matched for six days
- **WHEN** the coordinator fails over to another core node
- **THEN** the candidate is retired unactivated two days and five minutes later,
  not eight days after the failover

#### Scenario: A newer candidate supersedes an older one
- **GIVEN** epoch 1_000_000 is active and 1_000_001 is a candidate
- **WHEN** a core node with a catalog matching neither starts
- **THEN** it inserts candidate 1_000_002 and retires 1_000_001 without activating it
- **AND** readiness is evaluated only for 1_000_002

#### Scenario: A release is rolled forward and then rolled back before activation
- **GIVEN** epoch 1_000_000 is active
- **AND** a new release partially rolled out and inserted candidate 1_000_001
- **WHEN** the installation is rolled back so that no live core node's catalog
  matches 1_000_001
- **THEN** 1_000_000 stays active and core keeps signing under it
- **AND** after a full capability-lifetime window core retires 1_000_001 without
  activating it
- **AND** gateways drop 1_000_001 on their next refresh and pipeline status no
  longer reports readiness as incomplete
- **AND** no capability is ever signed under 1_000_001

#### Scenario: A fresh install activates its first epoch
- **GIVEN** a database with no epoch rows
- **WHEN** core starts
- **THEN** it inserts epoch 1_000_000 and activates it without waiting on a drain

### Requirement: Core activates a registry epoch only after every live component holds it
Core SHALL activate a `candidate` epoch only after two conditions hold. Every live
core node SHALL report the candidate's digest as its catalog digest. Every live
agent gateway SHALL report having installed a registry document that contains the
candidate. Activation SHALL happen in one transaction that makes the candidate
`active` and the previous epoch `draining`. Core SHALL NOT force activation on a
timeout. Until activation, core SHALL keep signing under the active epoch's
persisted document. After activation, core SHALL re-sign every agent's standing
grants under the new epoch, and SHALL supersede and re-lease every sweep slot
leased under the old epoch that has not started. A started slot SHALL finish under
the epoch it was leased in. While readiness is incomplete, the pipeline status
SHALL name the candidate epoch and each component that does not yet hold it.

#### Scenario: An upgrade changes a contract
- **GIVEN** epoch 1_000_000 is active and a new release changes a contract's bounds
- **WHEN** every core node runs the new release and every live gateway has
  installed a document containing candidate 1_000_001
- **THEN** core activates 1_000_001 and marks 1_000_000 draining in one transaction
- **AND** agents receive grants signed under 1_000_001 on their next config poll
- **AND** unstarted slots are re-leased under 1_000_001

#### Scenario: One gateway has not installed the candidate
- **GIVEN** a candidate epoch and a live gateway still holding only the active epoch
- **WHEN** core evaluates activation
- **THEN** the active epoch is unchanged
- **AND** the pipeline status names that gateway and the candidate epoch

#### Scenario: No operator steps are needed for an epoch change
- **WHEN** an installation upgrades to a release whose registry differs
- **THEN** no leasing switch, drain wait, or second upgrade is required for records
  to keep flowing

### Requirement: A draining epoch's backlog is admitted under its exact bundle until it retires
The agent gateway SHALL hold every non-retired epoch it receives from core, and
SHALL admit a record against the entry of the epoch the record names. It SHALL NOT
admit a record against the entry of the current epoch instead. EventWriter SHALL
validate a draining-epoch record with that epoch's entry and SHALL project it on
any core node that can project it under the projection rule of "Registry epochs
are persisted and only move forward". A delivery grant for a draining-epoch
backlog record SHALL be issued while the epoch drains. Core SHALL
compute a draining epoch's retirement time at activation. That time SHALL be no
earlier than the longest lifetime of any production capability core could have
signed under it, plus the maximum delivery-grant lifetime. Core SHALL retire the
epoch at that time. A record naming a retired epoch SHALL resolve as a counted
permanent rejection, `registry_epoch_retired`. It SHALL NOT be withheld.

#### Scenario: A changed bundle's backlog drains after activation
- **GIVEN** an agent spooled records under epoch 1_000_000 while offline
- **AND** epoch 1_000_001 changed that contract's bundle digest and is now active
- **WHEN** the agent reconnects before 1_000_000 retires
- **THEN** the gateway admits those records under 1_000_000's entry
- **AND** EventWriter projects them
- **AND** the lane watermark advances

#### Scenario: A forward upgrade changes a bundle at the same contract version
- **GIVEN** epoch 1_000_000 is active and agents spooled records for contract X
  under its bundle
- **AND** a new release changes X's bundle without bumping its contract version
- **WHEN** every core node runs the new release and epoch 1_000_001 activates
- **THEN** the backlog under 1_000_000's X bundle is admitted and projected by the
  new release's nodes, because their X bundle was introduced in a later epoch
- **AND** none of it is reported as awaiting roll-forward
- **AND** the lane watermark advances

#### Scenario: A record arrives after its epoch retired
- **WHEN** a record names an epoch that has retired
- **THEN** the gateway rejects it permanently as `registry_epoch_retired`
- **AND** the rejection is counted and the lane continues

### Requirement: Each registry epoch is signed by the issuer key and verified on every load
Core SHALL sign each registry epoch once, when it records the epoch, with the edge
issuer key. It SHALL store the signature and signing key id with the epoch. The
signature SHALL be Ed25519 over a `ServiceRadar.Edge.HashGrammar`-framed preimage
containing, in order:

- the domain tag `serviceradar.edge.contract_registry_epoch.v1` and the signature
  format version;
- the epoch number;
- the snapshot digest;
- the contract count;
- for each contract, sorted by `(contract_id, contract_version)`: its id, version,
  bundle digest, route profile, traffic class, partition rule, and cost model
  version.

The lifecycle state SHALL NOT be signed. Core SHALL verify every epoch it loads
from CNPG or from any cache before using it. Core SHALL NOT sign capabilities
under an epoch that fails verification. It SHALL report that epoch as
`registry_epoch_signature_invalid` in pipeline status, and SHALL issue no new
capability while the active epoch fails verification.

#### Scenario: A tampered epoch row in CNPG
- **GIVEN** an epoch row whose stored cost model version was altered after signing
- **WHEN** core's epoch reader loads it
- **THEN** verification fails and core excludes the epoch
- **AND** pipeline status reports `registry_epoch_signature_invalid` for it

#### Scenario: The signature binds the epoch number
- **WHEN** a signed epoch document is presented under a different epoch number
- **THEN** verification fails

### Requirement: Agents that would be off the pipeline are reported before the cutover release
A read-only edge pipeline readiness report SHALL ship in a release ahead of the
release that makes the pipeline default and removes the legacy status path. The
report SHALL list every agent that would be off the edge pipeline after that
upgrade, with a reason that includes `partition_not_found`,
`agent_upgrade_blocked`, or `agent_disconnected`. The report SHALL change no
agent, grant, lease, or data path behavior. It SHALL be readable through the API
and the web UI.

#### Scenario: An agent the rollout cannot reach
- **GIVEN** an agent pinned to a version older than the cutover release
- **WHEN** an operator opens the readiness report before upgrading
- **THEN** the agent is listed with `agent_upgrade_blocked`

#### Scenario: A ready installation
- **GIVEN** every agent resolves its partition, is connected, and can receive the
  cutover build
- **WHEN** an operator opens the readiness report
- **THEN** it lists no agent

### Requirement: Records stamped with an installation-static registry epoch are rejected, never withheld
The agent gateway SHALL resolve a record whose `registry_epoch` is below
1_000_000 as a counted permanent rejection, `static_registry_epoch`. This
classification SHALL take precedence over any withhold, including an unknown
issuer key id. Such a record SHALL NOT be withheld.

#### Scenario: An undrained spool survives the switch
- **GIVEN** an agent spooled records under a hand-written registry with epoch 2
- **WHEN** it delivers them after its installation upgrades to the derived registry
- **THEN** the gateway rejects each one as `static_registry_epoch`
- **AND** the agent quarantines them and later records on the lane are delivered

### Requirement: Core generates and stores its edge issuer key
Core SHALL generate its edge issuer Ed25519 seed on first use, and SHALL store it
in one CNPG row with the seed encrypted at rest by AshCloak and readable only by
core. Generation SHALL be insert-only, so concurrent replicas converge on one key
and a restart never changes it. Core SHALL NOT read the issuer key from a file,
the process environment, Helm values, or a Kubernetes Secret. Trust documents SHALL
carry only the public trust entry.

#### Scenario: A fresh install signs without a key file
- **GIVEN** a fresh installation with no issuer key row and no key file
- **WHEN** core first signs a standing grant
- **THEN** it generates and stores a seed and signs with it
- **AND** the gateway's next trust document carries that key's public entry

#### Scenario: Replicas race to generate the key
- **WHEN** two core replicas both find no issuer key row and generate seeds at once
- **THEN** exactly one row persists
- **AND** both replicas sign with the persisted seed

#### Scenario: A restored database keeps its key
- **GIVEN** a database backup restored with its original cloak key
- **WHEN** core starts
- **THEN** it uses the restored issuer key
- **AND** grants issued before the backup still verify

### Requirement: Conditions that keep an agent off the edge pipeline are visible on the agent
Core SHALL record a per-agent edge pipeline condition with a reason whenever an
agent cannot produce on the edge pipeline, and SHALL expose it in the agent's API
representation and in the web UI's agent detail. The reasons SHALL include:

- `partition_not_found`, when the agent's partition has no row;
- `no_live_gateway_on_active_epoch`;
- `spool_unavailable`, when the agent reports that its spool cannot be opened;
- `agent_upgrade_pending`, when the agent still runs a build from before the
  cutover release.

Core SHALL NOT create a partition from an agent-reported partition slug. A healthy
agent SHALL show no condition.

#### Scenario: An agent reports an unknown partition
- **GIVEN** an agent whose reported partition slug has no partition row
- **WHEN** core generates its config
- **THEN** the agent receives no grant
- **AND** its agent detail shows `partition_not_found` with the slug
- **AND** no partition row is created

#### Scenario: The partition is created later
- **GIVEN** an agent showing `partition_not_found`
- **WHEN** an operator creates that partition
- **THEN** the agent's next config carries its grants and the condition clears

### Requirement: The agent spool budget is a scoped runtime setting
Core SHALL resolve the agent spool byte budget from CNPG settings, in the order
agent, partition, global, then a code default of 1 GiB, and SHALL deliver it in the
agent config. The agent SHALL apply a delivered budget at spool admission. A
budget below current usage SHALL block only new appends until the spool drains
below it. No Helm value SHALL set the budget.

#### Scenario: An operator lowers one agent's budget
- **GIVEN** a global budget of 1 GiB and an agent-scoped budget of 256 MiB for one
  agent
- **WHEN** that agent receives its next config
- **THEN** its spool admits new records only while usage is under 256 MiB
- **AND** other agents keep the 1 GiB budget
