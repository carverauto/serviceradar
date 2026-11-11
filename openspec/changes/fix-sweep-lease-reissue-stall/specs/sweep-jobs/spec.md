# Spec Deltas: fix-sweep-lease-reissue-stall — sweep-jobs

## ADDED Requirements

### Requirement: Session lease re-issue skips already-recorded valid issuance

When an agent opens a new control session, core MUST NOT redo signing,
evidence replay, and per-slot issuance commits for slots whose issuance is
already recorded, still valid, AND reported held by the agent. The re-issue
SHALL return the window verified current when ALL hold: the plan targets the
same lease id as the recorded delivery, the delivery shows an installed
acknowledgement on the delivered digest, every unrun slot was already carried
with no drops and an unchanged check set, the freshly computed authority
fingerprint (issuer key id, contract identity, lease issued-at) equals the
fingerprint stored at `record_push`, and the session hello reports the same
installed window digest for the group. Otherwise core MUST rebuild, commit,
and send exactly as before, and MUST still commit issuance evidence before
sending. An agent never runs a slot core has no issuance evidence for, and
core never believes an agent holds a window it does not: belief is digest
equality, never trust.

#### Scenario: Reconnect on an unchanged window performs no writes or sends

- **GIVEN** an agent with a recorded delivery acked-installed on its digest
- **AND** the same lease id, slot set, check set, and authority fingerprint
- **AND** a session hello reporting the same installed digest for the group
- **WHEN** the agent opens a new control session and core re-issues
- **THEN** core SHALL sign nothing, write no issuance rows, and send no push
- **AND** the refresh SHALL report the window verified current with the digest.

#### Scenario: Hello digest mismatch re-issues that group only

- **GIVEN** a recorded delivery acked-installed on its digest
- **AND** a session hello reporting a different digest, or none, for a group
  core believes is leased
- **WHEN** the agent opens a new control session and core re-issues
- **THEN** core SHALL rebuild, commit, and send that group's window
- **AND** groups with matching digests SHALL still skip.

#### Scenario: Agent without the hello capability keeps today's behavior

- **GIVEN** an agent whose hello carries no installed-window digests
- **WHEN** the agent opens a new control session and core re-issues
- **THEN** core SHALL rebuild, commit, and send every leased group exactly
  as before, with batched commits
- **AND** no group SHALL skip on trust alone.

#### Scenario: Changed authority rebuilds and resends

- **GIVEN** a recorded delivery whose authority fingerprint differs from the
  current issuer key, contract, or lease issued-at
- **WHEN** the agent opens a new control session and core re-issues
- **THEN** core SHALL rebuild the window, commit issuance evidence, and send
  the push before reporting success.

#### Scenario: Issuance evidence commits in batches

- **GIVEN** a full-window rebuild over more slots than fit one issuance batch
- **WHEN** core commits the mapping evidence
- **THEN** it SHALL commit in 4,096-entry batches rather than one transaction
  per slot
- **AND** every entry SHALL still pass verification
- **AND** a conflicting entry SHALL still halt the push before anything is sent.

### Requirement: Lease delivery locks are bounded

No lease delivery path SHALL wait on the per-agent delivery lock without a
bound. A lease pass that finds an agent's delivery in progress MUST skip that
agent for the pass and deliver it on a later pass; a session refresh that
finds the lock held MUST return a bounded busy error for the gateway retry
instead of parking. A skipped agent SHALL lose nothing because delivery state
is untouched by the skip.

#### Scenario: Pass skips a busy agent

- **GIVEN** a session refresh holds an agent's delivery lock
- **WHEN** the lease pass reaches that agent
- **THEN** the pass SHALL skip the agent with a debug log naming agent and group
- **AND** the pass SHALL continue with the remaining agents
- **AND** a later pass SHALL deliver the skipped agent.

#### Scenario: Refresh on a busy lock returns promptly

- **GIVEN** a lease pass holds an agent's delivery lock
- **WHEN** a session refresh requests that agent's lease
- **THEN** the refresh SHALL return a delivery-in-progress error without
  waiting on the lock
- **AND** the gateway backoff SHALL retry the refresh later.
