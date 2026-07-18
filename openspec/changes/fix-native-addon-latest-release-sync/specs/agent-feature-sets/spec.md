## ADDED Requirements

### Requirement: Unattended native add-on sync follows one authoritative release

The control plane SHALL treat the newest import-ready signed native add-on release
index as the complete unattended synchronization set. It SHALL NOT retry packages
from historical release indexes unless an authorized operation explicitly selects
that historical release tag.

#### Scenario: Scheduled sync selects the newest indexed release

- **GIVEN** discovery returns import-ready native add-ons from several releases in newest-first order
- **WHEN** unattended synchronization runs without a release tag
- **THEN** only entries belonging to the newest import-ready release SHALL be candidates
- **AND** omitted add-ons or older versions SHALL NOT be filled from historical releases

#### Scenario: Operator explicitly selects a historical release

- **GIVEN** discovery contains a historical signed native add-on release
- **WHEN** an authorized import requests that exact release tag
- **THEN** only entries from the requested release SHALL be candidates
- **AND** the newest-release default SHALL NOT override the explicit request

### Requirement: Native add-on versions identify immutable verified content

The control plane SHALL NOT replace an occupied native add-on semantic version
with a different verified bundle or artifact contract, even when both sources are
signed first-party releases. A changed payload SHALL be published under a new
semantic version before automatic import or approval can proceed.

#### Scenario: Changed signed payload reuses an occupied version

- **GIVEN** an imported verified first-party add-on version with recorded bundle and artifact digests
- **AND** a later signed release declares the same add-on version with different content digests
- **WHEN** synchronization evaluates the later entry
- **THEN** synchronization SHALL fail closed with an immutable source conflict
- **AND** SHALL preserve the existing package and assignments unchanged

#### Scenario: Changed payload is published under a new version

- **GIVEN** a later signed release declares changed add-on content under a new semantic version
- **WHEN** synchronization verifies its manifest, bundle, and artifact signatures
- **THEN** it SHALL import the new package as a distinct immutable version
- **AND** existing historical versions SHALL remain available for audit and rollback

### Requirement: Trusted native add-on repair converges through deployment policy

The control plane SHALL re-evaluate the deployment's configured auto-approval
allowlist after a verified first-party native add-on is repaired or synchronization
finds an otherwise reusable verified package left staged by an interrupted repair.
It SHALL NOT require per-package operator approval for an allowlisted package, and
SHALL NOT override an explicit denied or revoked review state.

#### Scenario: Interrupted repair left an allowlisted package staged

- **GIVEN** a verified first-party package is staged and covered by the deployment auto-approval allowlist
- **AND** its persisted content matches the authoritative signed release entry
- **WHEN** unattended synchronization evaluates the package
- **THEN** the package SHALL become approved without operator interaction
- **AND** dependent profile reconciliation SHALL be able to resume

#### Scenario: Explicitly rejected package requires operator action

- **GIVEN** a first-party package was denied or revoked before a verified repair
- **WHEN** unattended synchronization repairs its persisted artifacts
- **THEN** the package SHALL retain its denied or revoked state
- **AND** synchronization SHALL NOT restore approval automatically
