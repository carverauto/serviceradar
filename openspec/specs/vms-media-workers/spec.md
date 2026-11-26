# vms-media-workers Specification

## Purpose
Execution-time scoped fragment read grants that let an external media worker, such as the one in the commercial ServiceRadar Vantage addon, read recorded camera blocks without holding storage credentials. Media analysis itself runs outside ServiceRadar.

## Requirements
### Requirement: Execution-time scoped fragment read grants
The system SHALL issue short-lived, catalog-entry-scoped fragment read grants (`POST /v1/media/workers/read-grants`) only to callers authenticated with the dedicated `media_worker` workload credential, restricting archive access to `:reader`-only (`GET`, `HEAD`) `CredentialBrokerGrant` leases resolved from `platform.network_credential_secrets`, or to the NVR's dedicated analysis-read pool for blocks not yet archived. Each grant SHALL carry the frozen descriptor's SHA-256 digests so the caller can verify every byte it reads.

#### Scenario: Ranged archive fetch through a short-lived reader grant
- **WHEN** an authenticated media worker requests a read grant for a playable `RecordingCatalogEntry` served from S3-compatible object storage, naming its `catalog_entry_id`, `descriptor_sha256` and optionally `fragment_sequences` (up to 64 comma-separated sequence numbers, since the control-plane JSON contract carries no arrays)
- **THEN** the endpoint SHALL return a `:reader`-only grant locked to the binding's host, bucket and prefix, short-lived pre-signed URLs, and only the requested fragment byte ranges (every fragment when none are named) with their frozen SHA-256 digests
- **AND** the response SHALL never contain secret key material

#### Scenario: Local NVR fetch isolated from interactive playback
- **WHEN** the requested block has `local_state = present` and no verified archive copy
- **THEN** the grant SHALL direct the worker to the NVR analysis-read pool, which SHALL NOT consume interactive playback or archive upload read slots

#### Scenario: Caller job bookkeeping stays with the caller
- **WHEN** a request carries an opaque `job_id`
- **THEN** the endpoint SHALL echo it in the grant and SHALL NOT read or change any job state

#### Scenario: Deleted or quarantined block
- **WHEN** a worker requests a grant for a `catalog_entry_id` that is quarantined or has no remaining playable copy
- **THEN** the endpoint SHALL refuse media access with `410 Gone` (`recording_gone`)

#### Scenario: Descriptor digest mismatch or oversized request
- **WHEN** the request's `descriptor_sha256` differs from the catalog entry's, or it names more than 64 fragments
- **THEN** the endpoint SHALL refuse the grant with `409 descriptor_sha256_mismatch` or `400 too_many_fragments`
