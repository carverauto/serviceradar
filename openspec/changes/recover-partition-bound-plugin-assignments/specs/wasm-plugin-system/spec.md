## ADDED Requirements

### Requirement: Authenticated partition binding for plugin assignments
The control plane SHALL derive the partition of every enabled plugin assignment
from current server-observed mTLS control-session evidence for the selected
agent. Assignment inputs, plugin configuration, persisted agent metadata, and
legacy rows SHALL NOT supply or override that partition.

#### Scenario: Online agent is assigned in its authenticated partition
- **GIVEN** an authorized assignment path selects an online agent whose current authenticated control session identifies partition `default`
- **WHEN** it creates a plugin assignment
- **THEN** the control plane creates the assignment in partition `default`
- **AND** the value comes from current server-observed control-session evidence

#### Scenario: Identity evidence is unavailable or inconsistent
- **GIVEN** an agent is offline or current control-session evidence does not identify that agent and a nonempty partition
- **WHEN** manual, policy, or automatic recovery attempts assignment creation
- **THEN** the control plane creates no enabled assignment
- **AND** a later automatic sweep may retry after current evidence becomes available

#### Scenario: Caller attempts to select a partition
- **GIVEN** a caller supplies a partition in an assignment request or historical configuration
- **WHEN** the control plane evaluates the request
- **THEN** the caller-supplied value does not control routing
- **AND** the action uses fresh authenticated evidence or fails closed

### Requirement: Trusted first-party manual recovery is automatic
The control plane SHALL periodically process disabled partition-unbound manual
assignments in bounded keyset pages. It SHALL create a fresh assignment without
operator confirmation only for an approved, verified, signed, content-addressed
first-party package and only after current mTLS, schema, secret-reference, and
conflict checks pass. The historical row SHALL remain disabled and unbound.

The first-party upload-signature verifier SHALL preserve JSON collection types
when producing the canonical signed payload, including the distinction between
an empty object and an empty array.

#### Scenario: Signed manifest contains empty collections
- **GIVEN** a signed first-party manifest contains both an empty object and an empty array
- **WHEN** the control plane verifies the package for trusted import or recovery
- **THEN** it canonicalizes the object as `{}` and the array as `[]`
- **AND** a valid release signature is not rejected because the collection types were collapsed

#### Scenario: Periodic trusted catalog sync schedules its successor
- **GIVEN** the hourly first-party Wasm catalog sync is currently executing
- **WHEN** that successful execution schedules its periodic successor
- **THEN** the successor uniqueness check excludes the currently executing row
- **AND** exactly one future sync remains scheduled at the configured interval
- **AND** the minute-scale bootstrap guard does not become the normal execution cadence

#### Scenario: Compatible trusted assignment recovers
- **GIVEN** a disabled unbound manual assignment references a trusted first-party package
- **AND** its parameters satisfy the current package schema
- **AND** the exact agent has current authenticated control-session evidence and no current assignment conflict
- **WHEN** the automatic recovery worker processes the row
- **THEN** it creates one fresh assignment in the current authenticated partition
- **AND** it records an immutable audit link to the replacement
- **AND** no browser action or confirmation is required

#### Scenario: Uploaded or unverified package remains quarantined
- **GIVEN** a disabled unbound assignment references an uploaded, unsigned, unverified, non-first-party, or unavailable package
- **WHEN** the automatic worker evaluates it
- **THEN** no assignment is created or enabled
- **AND** the row remains disabled history rather than becoming an operator recovery task

#### Scenario: Current schema rejects historical parameters
- **GIVEN** a trusted first-party legacy assignment no longer satisfies the current package schema
- **WHEN** automatic recovery evaluates it
- **THEN** no replacement is created
- **AND** the system does not manufacture required values or expose a per-row approval action

#### Scenario: Recovery is idempotent
- **GIVEN** automatic recovery already created and audited a replacement
- **WHEN** a periodic sweep processes the historical row again
- **THEN** it returns the recorded replacement outcome
- **AND** it does not create a duplicate enabled assignment

#### Scenario: Fresh manual intent is independent of history
- **GIVEN** an agent has disabled unbound historical rows for a plugin
- **AND** no current assignment or policy conflicts with new manual intent
- **WHEN** an authorized operator creates a new assignment with current configuration
- **THEN** the ordinary create path uses fresh mTLS evidence
- **AND** historical rows neither block the create nor become update targets

### Requirement: Policy-owned recovery uses authoritative reconciliation
The control plane SHALL ignore policy-owned history in the automatic manual
worker and SHALL rely on current plugin-target-policy and credential-rule
reconcilers to restore desired state. Historical rows SHALL NOT be cloned, used
as authority, or require browser reconciliation.

#### Scenario: Current owner recreates desired state
- **GIVEN** a current enabled policy or credential rule still targets an agent and plugin
- **WHEN** its ordinary reconciler evaluates current desired state
- **THEN** it may create a fresh assignment after current owner, package, schema, credential, and mTLS checks pass
- **AND** no historical configuration or operator recovery event is used

#### Scenario: No current owner expresses desired state
- **GIVEN** a historical policy row has no enabled supported owner that currently targets the agent
- **WHEN** reconcilers run
- **THEN** no replacement is created from history
- **AND** the disabled row remains non-actionable audit history

### Requirement: Automatic recovery is bounded and retry-safe
The recovery scheduler SHALL enqueue unique bounded work. A job SHALL process at
most its configured page size and SHALL continue with an opaque keyset cursor
when more candidates exist. Terminal trust, schema, and conflict outcomes SHALL
not be retried continuously, while transient identity or persistence failures MAY
be retried by a later sweep.

#### Scenario: Candidate inventory exceeds one page
- **GIVEN** more quarantined rows exist than the worker page size
- **WHEN** the first job completes
- **THEN** it schedules the next keyset page
- **AND** no job loads the complete inventory into memory

#### Scenario: Base sweep is already scheduled
- **GIVEN** an incomplete base recovery job already exists
- **WHEN** the periodic scheduler runs again
- **THEN** Oban uniqueness prevents a duplicate overlapping base sweep
