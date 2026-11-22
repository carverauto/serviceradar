## ADDED Requirements

### Requirement: Scheduled visual index outbox relay
When the deployment enables camera recording and visual indexing, Core SHALL relay `platform.camera_visual_index_jobs` to NATS JetStream on a fixed schedule. Each run SHALL first reconcile expired jobs in deadline order, then dispatch pending jobs with live jobs before backfill jobs. Each phase SHALL process at most ten batches of 100 jobs. Core SHALL mark a job `dispatched` only after `CAMERA_MEDIA_JOBS` acknowledges its publish. Core SHALL NOT create the worker-owned `CAMERA_MEDIA_JOBS` stream, and SHALL NOT re-publish a dispatched job while its earlier message can still be held by that stream.

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
- **WHEN** a dispatched job has reached both its stored deadline and 72 hours from the later of its dispatch timestamp and post-publish row update without a result
- **THEN** the relay SHALL re-publish it under the next attempt, or mark it `failed_terminal` once its attempt budget is spent and attempt a best-effort `TripwireHealth` record

#### Scenario: Visual indexing disabled for the deployment
- **WHEN** camera recording or visual indexing is not enabled for the deployment
- **THEN** Core SHALL NOT schedule the relay, and a previously queued tick SHALL finish without relaying jobs

### Requirement: Durable visual index result consumer
When the deployment enables camera recording and visual indexing, Core SHALL consume `media.results.visual_index.v1` through a durable EventWriter JetStream consumer bound to the worker-owned `CAMERA_MEDIA_RESULTS` stream and project each result into CNPG through the idempotent result projector, in batches of 10 with a pending acknowledgement budget of 20 per EventWriter worker (60 on a three-replica deployment).

#### Scenario: Result is stored and acknowledged
- **WHEN** a valid result matches an active admitted job for a playable catalog entry
- **THEN** Core SHALL upsert its visual frames and embeddings, mark the job `completed`, and acknowledge the message. EventWriter SHALL count the embedding rows written, including in a partially successful batch

#### Scenario: Replayed result
- **WHEN** a matching result arrives for a completed, cancelled or terminally failed job with a playable recording
- **THEN** Core SHALL acknowledge it with zero writes and preserve the final job state and any prior purge

#### Scenario: Recording deleted or quarantined while the worker ran
- **WHEN** a matching result arrives for an admitted job whose catalog entry is quarantined or terminally deleted
- **THEN** Core SHALL store nothing, cancel the entry's active jobs, and acknowledge the message

#### Scenario: Recording copy temporarily unavailable
- **WHEN** a matching result arrives for an active job while its recording has no playable copy and can still recover
- **THEN** Core SHALL retry the delivery without writing projections or cancelling jobs

#### Scenario: Invalid result for a final job
- **WHEN** a matching malformed result arrives after completion, cancellation or terminal failure
- **THEN** Core SHALL dead-letter the result and preserve the job and its recorded health metadata

#### Scenario: Transient failure
- **WHEN** storing a result fails for a reason a later delivery can overcome, such as a database error, and deliveries remain
- **THEN** Core SHALL NAK the message with backoff so JetStream redelivers it

#### Scenario: Result that can never be stored
- **WHEN** a result fails validation, such as a malformed envelope, an invalid vector or bounding box, or a descriptor digest that does not match the catalog entry
- **THEN** when the database accepts the update, Core SHALL first mark the active job whose identity matches the decoded envelope `failed_terminal` with the failure class, attempt a best-effort `TripwireHealth` record for that failure, record the dead letter, and terminate the message without redelivery

#### Scenario: Result has no matching admitted job
- **WHEN** the result does not match an admitted job by catalog entry, descriptor digest, detector and embedder IDs and versions, embedding dimension, and job ID when supplied
- **THEN** Core SHALL terminate the delivery and emit the dead-letter metric without projecting data or changing any job

#### Scenario: The database is unavailable throughout delivery of a permanently invalid result
- **WHEN** the database is unavailable for all ten deliveries of a permanently invalid result for a dispatched job
- **THEN** Core SHALL terminate the tenth delivery while the job is still dispatched
- **AND** after the retention floor and stored deadline pass, expired-job reconciliation SHALL republish the job as the next attempt or mark it `failed_terminal` if its attempt budget is exhausted
