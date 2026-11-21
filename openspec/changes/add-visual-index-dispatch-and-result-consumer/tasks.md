# Tasks

## 1. Outbox relay schedule
- [x] 1.1 Add `VisualIndexDispatcher.relay/1`: reconcile expired dispatched jobs, then publish pending jobs (live first), in bounded batches, stopping at the first failed publish.
- [x] 1.2 Mark a job `dispatched` with a compare-and-set on the state and attempt it was read with.
- [x] 1.3 Set the re-dispatch deadline to the `CAMERA_MEDIA_JOBS` retention (72 hours).
- [x] 1.4 Add `VisualIndexDispatchWorker` (Oban, `:maintenance`, no overlapping runs) and its once-a-minute `CoreCrontab` entry, gated on camera recording and visual indexing.

## 2. Result consumer
- [x] 2.1 Add the `CAMERA_VISUAL_INDEX_RESULTS` EventWriter stream (`media.results.visual_index.v1` on the worker-owned `CAMERA_MEDIA_RESULTS`, `ensure_stream: false`) to both core runtime stream lists under the same gate.
- [x] 2.2 Add the `CameraVisualIndexResults` processor and route the subject to it.
- [x] 2.3 Add typed transient and terminal failures to the EventWriter ack path: NAK with backoff, and TERM with a dead-letter record.
- [x] 2.4 Commit the job cancellation for a result whose recording is gone instead of rolling it back.
- [x] 2.5 Decode a JSON result with arrays allowed (the array-free `JSONDocument` rejected every real result).

## 3. Permissions
- [x] 3.1 Allow core to publish `media.jobs.visual_index.v1` and `media.jobs.visual_index.backfill.v1`, with a helm unittest.
- [ ] 3.2 Before enabling visual indexing in any multi-identity deployment, the chart permissions follow-up must narrow the existing JetStream API grants for agent, web-ng, gateway, datasvc, flowgger, OTEL, trapd, BMP and Falco. These grants allow those identities to read camera job metadata and visual results outside camera-scoped search.

## 4. Verification
- [x] 4.1 Integration tests on a scratch `srql-fixtures` database: publish once and mark after the acknowledgement, failed publish stays pending, concurrent relays advance a job once, a queued job is not re-published, an expired job is re-published, and the result consumer stores, replays, retries and terminates.
- [x] 4.2 Unit tests for the ack path and the deployment gate.
