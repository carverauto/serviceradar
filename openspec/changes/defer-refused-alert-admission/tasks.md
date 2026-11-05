## 1. Durable deferral
- [x] 1.1 Generalize `lifecycle_pending_admissions` into `alert_pending_admissions` with `lifecycle`, `event` and `metric` lanes (migration `20261105100000`), and bump `core.migrations.expectedVersion`.
- [x] 1.2 Add `AlertAdmissionBacklog`: direct admission while a lane is empty, deferral on a retryable refusal or behind a non-empty lane, chunked head admission under a per-lane try-lock.
- [x] 1.3 Route `StatefulEvaluationLedger.evaluate_once/2` and `evaluate_metrics/1` through it, recording the ledger marker in the deferral's transaction and running the promotion callback before it.
- [x] 1.4 Stop failing lifecycle messages on a retryable refusal; keep failing them on any other refusal.
- [x] 1.5 Remove the pipeline's retryable alert-evaluation backoff and dead-letter branch.

## 2. Drain and visibility
- [x] 2.1 Rename the drain worker to `AlertAdmissionDrainWorker` and drain the event and metric lanes after the lifecycle series.
- [x] 2.2 Report per-lane count and oldest age as telemetry and as the `alert_admission_backlog` ingestion lane, and record the `alert-admission-backlog` core health check.
- [x] 2.3 Update `docs/alert-evaluation-rollout.md` and the table and worker names in `scale-alert-evaluation-pipeline`.

## 3. Proof
- [x] 3.1 Falco: an overloaded evaluation is acknowledged on every delivery past `max_deliver`, the event is stored once, and the drain admits it from its snapshot.
- [x] 3.2 Lifecycle: an overloaded final delivery is acknowledged and its transition stays pending until admitted.
- [x] 3.3 Backlog: records arriving behind an event or metric backlog are admitted after it, in order; a genuine refusal defers nothing; the report turns unhealthy past its age threshold.
- [x] 3.4 Log promotion: an overloaded evaluation raises the promotion alert once and is admitted from the backlog.
- [ ] 3.5 Run the DB-backed tests on a scratch database or in BazelCI Core Integration.
