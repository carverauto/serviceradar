## ADDED Requirements

### Requirement: Scheduled visual index outbox relay
When the deployment enables camera recording and visual indexing, Core SHALL relay `platform.camera_visual_index_jobs` to NATS JetStream on a fixed schedule. Each run SHALL do bounded work, publish live jobs before backfill jobs, and mark a job `dispatched` only after the stream acknowledges its publish. Core SHALL NOT create the worker-owned `CAMERA_MEDIA_JOBS` stream, and SHALL NOT re-publish a dispatched job while its earlier message can still be held by that stream.

#### Scenario: Pending job is published once and marked after the acknowledgement
- **WHEN** the relay runs and a `pending` job exists
- **THEN** Core SHALL publish its metadata-only envelope once, with `Nats-Msg-Id` derived from the job id and attempt, and SHALL mark the job `dispatched` only after the publish is acknowledged

#### Scenario: No media worker has created the jobs stream
- **WHEN** the relay publishes a job and the stream does not acknowledge it, for example because no media worker has created `CAMERA_MEDIA_JOBS`
- **THEN** the job SHALL stay `pending` with its attempt count unchanged, and the run SHALL stop publishing until the next scheduled run

#### Scenario: Two relays read the same job
- **WHEN** two Core replicas read the same job and both publish it
- **THEN** both publishes SHALL carry the same `Nats-Msg-Id` so the stream stores one message, and only one replica SHALL advance the job's state and attempt count

#### Scenario: Dispatched job still queued behind a worker backlog
- **WHEN** a dispatched job has not completed but the stream can still hold its message
- **THEN** the relay SHALL NOT re-publish it or count another attempt

#### Scenario: Dispatched job whose message can no longer be queued
- **WHEN** a dispatched job's reconcile deadline has passed without a result
- **THEN** the relay SHALL re-publish it under the next attempt, or mark it `failed_terminal` with a `TripwireHealth` record once its attempt budget is spent

#### Scenario: Visual indexing disabled for the deployment
- **WHEN** camera recording or visual indexing is not enabled for the deployment
- **THEN** Core SHALL NOT schedule the relay

### Requirement: Durable visual index result consumer
When the deployment enables camera recording and visual indexing, Core SHALL consume `media.results.visual_index.v1` through a durable EventWriter JetStream consumer bound to the worker-owned `CAMERA_MEDIA_RESULTS` stream and project each result into CNPG through the idempotent result projector, with bounded batch size and in-flight messages.

#### Scenario: Result is stored and acknowledged
- **WHEN** a valid result for a playable catalog entry arrives
- **THEN** Core SHALL upsert its visual frames and embeddings, mark the job `completed`, and acknowledge the message

#### Scenario: Replayed result
- **WHEN** a result that was already stored is delivered again
- **THEN** Core SHALL leave one projection set for the entry and model and acknowledge the message

#### Scenario: Recording deleted or quarantined while the worker ran
- **WHEN** a result arrives for a catalog entry that is missing or no longer playable
- **THEN** Core SHALL store nothing, cancel the entry's active jobs, and acknowledge the message

#### Scenario: Transient failure
- **WHEN** storing a result fails for a reason a later delivery can overcome, such as a database error
- **THEN** Core SHALL NAK the message with backoff so JetStream redelivers it

#### Scenario: Result that can never be stored
- **WHEN** a result fails validation, such as a malformed envelope, an invalid vector or bounding box, or a descriptor digest that does not match the catalog entry
- **THEN** Core SHALL mark the named job `failed_terminal` with the failure class, record the dead letter, and terminate the message without redelivery
