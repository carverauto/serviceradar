# Change: Schedule the visual index outbox relay and consume worker results

## Why

`add-camera-semantic-clip-search` was archived as complete while two links of its
loop were missing in Core:

- Nothing published the `platform.camera_visual_index_jobs` outbox. The
  dispatcher functions existed, but no scheduler, cron entry or supervisor called
  them, so every admitted job stayed `pending` and no media worker received work.
- Nothing consumed `media.results.visual_index.v1`. The result projector existed
  as a library, but no JetStream consumer called it, so no embedding reached
  `platform.camera_visual_frames` or `platform.camera_visual_embeddings`.

Three defects surfaced once both links run. The projector decoded a JSON
result as an array-free document, so every real worker result (an object of
frame, detection and embedding arrays) was rejected as invalid. A dispatched job was
re-published once its 60-second deadline passed, even while the first copy
was still queued in `CAMERA_MEDIA_JOBS`. A worker backlog longer than a few
minutes therefore re-published each job until it was marked `failed_terminal`
while still queued. The dispatched-state update also did not compare the
attempt it read, so two concurrent relays could both advance one job.

## What Changes

- The result projector decodes a JSON result with arrays, within its existing
  4 MiB bound, and commits the job cancellation for a result whose recording
  is gone instead of rolling it back with the aborted projection.
- Core runs the outbox relay as an Oban cron job, once a minute, on the
  core-only `:maintenance` queue. Each tick reconciles expired dispatched jobs,
  then publishes pending jobs (live before backfill). Both phases work in
  bounded batches and stop at the first failed publish.
- A job is marked `dispatched` only after the stream acknowledges the publish,
  with a compare-and-set on the attempt it read. The `Nats-Msg-Id` is derived
  from the job id and attempt, so a concurrent duplicate is absorbed by the
  stream's duplicate window and only one relay advances the job.
- Core does not create `CAMERA_MEDIA_JOBS`. The media worker owns that stream.
  Until a worker has created it, publishes fail and jobs stay `pending`.
- A dispatched job is re-published only after `CAMERA_MEDIA_JOBS` would have
  aged out its message (72 hours), never while that message can still be
  queued.
- EventWriter consumes `media.results.visual_index.v1` from the worker-owned
  `CAMERA_MEDIA_RESULTS` stream with a durable consumer and calls the result
  projector. It acks results that are stored or replayed, and results whose
  recording is gone. It NAKs transient failures with backoff. Results that can
  never be stored are terminated and recorded as dead letters. When the database
  accepts the update, Core first marks the named job `failed_terminal`. If the
  database is unavailable for all ten deliveries, the result is terminated while
  its job is still dispatched. After the retention floor and deadline pass, the
  relay republishes the next attempt or marks the job `failed_terminal` if its
  attempt budget is exhausted.
- The relay and the consumer run only when the deployment enables both camera
  recording (`SERVICERADAR_CAMERA_RECORDING_ENABLED`) and visual indexing
  (`SERVICERADAR_CAMERA_VISUAL_INDEXING_ENABLED`).
- Core's NATS identity may publish `media.jobs.visual_index.v1` and
  `media.jobs.visual_index.backfill.v1`.

Setting a camera policy's `visual_index_mode` to `:off` stops new live job admission. Previously admitted jobs can still be dispatched or retried, receive read grants, and produce indexed results. Revoking those jobs is a follow-up.

## Impact

- Affected specs: `camera-semantic-search`
- Affected code: `ServiceRadar.Camera.VisualIndexDispatcher`,
  `ServiceRadar.Camera.VisualIndexDispatchWorker`,
  `ServiceRadar.Camera.VisualIndexResultProjector`,
  `ServiceRadar.Jobs.CoreCrontab`, `ServiceRadar.EventWriter.{Config,Pipeline}`,
  `ServiceRadar.EventWriter.Processors.CameraVisualIndexResults`, both core
  `runtime.exs` stream lists, and `helm/serviceradar/templates/_nats_static_users.tpl`.
- Not in this change: the media worker's NATS identity, its permissions, the
  chart wiring of `SERVICERADAR_CAMERA_VISUAL_INDEXING_ENABLED` and model ids,
  and the JetStream budget for the worker-owned streams.
