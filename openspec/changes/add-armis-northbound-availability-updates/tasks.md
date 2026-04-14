## 1. Investigation and design
- [ ] 1.1 Trace where the current system can read the latest consolidated Armis device availability from the database instead of NATS KV.
- [ ] 1.2 Confirm the current config/UI path still delivers `custom_field`, credentials, and per-source scheduling settings needed for northbound jobs.
- [ ] 1.3 Compare the current runtime with the historical updater/reconcile flow from `pkg/sync/integrations/armis/` and identify reusable logic versus code that should stay retired.
- [ ] 1.4 Document the target architecture for DB-backed state, AshOban scheduling, metrics, and event emission.

## 2. Scheduling and data model
- [ ] 2.1 Define how an Armis integration source stores its northbound update cadence and enablement in the database.
- [ ] 2.2 Add an Ash/AshOban-backed job path for recurring Armis northbound updates with uniqueness and run history.
- [ ] 2.3 Support manual "run now" execution for an Armis northbound update job.
- [ ] 2.4 Ensure the scheduler behaves safely when the integration is disabled, misconfigured, or missing `custom_field`.

## 3. Northbound Armis update execution
- [ ] 3.1 Add an Armis northbound updater client using the existing endpoint/auth configuration.
- [ ] 3.2 Read the latest consolidated availability from database-backed state, not legacy KV payloads.
- [ ] 3.3 Correlate updates by `armis_device_id` and emit one outbound update per Armis device.
- [ ] 3.4 Batch outbound updates through Armis custom-property bulk APIs.
- [ ] 3.5 Surface partial/full failures in persisted run status, error details, and logs.

## 4. UI and operator workflows
- [ ] 4.1 Extend Settings -> Network -> Integrations so users can configure northbound scheduling for Armis sources.
- [ ] 4.2 Show inbound discovery status separately from northbound update status so dead-code-pathed behavior is replaced with explicit runtime state.
- [ ] 4.3 Expose recent northbound runs, failures, and "run now" controls in the appropriate integrations/jobs surfaces.

## 5. Metrics and events
- [ ] 5.1 Emit metrics for Armis northbound job runs, batch sizes, success/failure counts, and execution latency.
- [ ] 5.2 Create database-backed success/failure events after each northbound update run.
- [ ] 5.3 Ensure event writes drive existing Events UI refresh behavior.

## 6. Verification
- [ ] 6.1 Add unit tests for Armis northbound payload construction and bulk request handling.
- [ ] 6.2 Add tests covering multi-IP or multi-target devices collapsing to one outbound update per `armis_device_id`.
- [ ] 6.3 Add tests for AshOban schedule creation, disablement, uniqueness, and manual run behavior.
- [ ] 6.4 Extend faker as needed so `demo` can validate northbound bulk updates via in-memory readback/debug state.
- [ ] 6.5 Add an integration-style test covering discovery -> sweep availability -> scheduled northbound Armis update.
- [ ] 6.6 Validate this change with `openspec validate add-armis-northbound-availability-updates --strict`
