# Async integration audit

This record is the first, deliberately conservative, async wave for the core
integration shards. Each promoted module uses the non-shared rollback-only
`ServiceRadar.DataCase` owner supplied to its test process. None starts a
database child process, so none needs `ServiceRadar.DataCase.allow_sandbox/1`.

## Promoted modules

| Source | Transaction and identifier evidence | Excluded shared-state behavior |
| --- | --- | --- |
| `test/integration/advisory_feed_loader_integration_test.exs` | Loader reads and writes in the test body use the test's Repo owner. The `loader-itest-#{System.unique_integer(...)}` feed key scopes the provider/feed rows and coordinates to one test. The `on_exit` cleanup runs in a separate process, is best-effort, and is not relied on for isolation; the rollback-only DataCase owner rolls the test body back. | No unboxed mode, DDL, application mutation, external service, global database worker, or child process. |
| `test/integration/secret_broker_audit_integration_test.exs` | Provider, secret, and audit writes execute synchronously through the calling test transaction. The provider name, secret name, external reference, grant ID, and consumer ID include one `System.unique_integer/1` value. | No unboxed mode, DDL, application mutation, external service, global database worker, or child process. |

## Explicit serial decisions

| Source or lane | Reason it remains serial |
| --- | --- |
| Credential event writer | Mutates application environment to exercise the success-event flag. |
| Credential broker grant lifecycle | `setup_all` starts core and mutates application configuration. |
| Ordinary ResultsRouter | Mutates three application environment values for ingestion behavior. |
| First-user role assignment | Uses unboxed sandbox mode, `TRUNCATE`, and true multiple database connections. |
| Onboarding package atomicity | Uses unboxed mode, global crypto configuration, and lock-visibility behavior. |
| Remote access sessions | Mutates application configuration, uses task concurrency, and performs committed cleanup. |
| Composite check, rule, input, and device-result modules | Each creates `CompositeCheck`, whose registered `ScheduleNotifier.notify/1` calls `EvaluationWorker.cancel/1` for the draft record; that calls global `Oban.cancel_all_jobs/1`. This application-supervised database worker cannot be shared by concurrent owners. |
| NetFlow ingestion | Uses a fixed external NATS resource and is pinned to the serial `s7` lane. |
| Ad-hoc scan NATS E2E | Uses a fixed external NATS resource and is pinned to the serial `s7` lane. |
| Proxmox smoke | Uses a fixed external resource and is pinned to the serial `s7` lane. |

Rollup and `RemoteAccessHostKeys` are intentionally outside this first wave and remain serial.
