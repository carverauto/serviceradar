# Async integration audit

This record is the first, deliberately conservative, async wave for the core
integration shards. Each promoted module uses the non-shared rollback-only
`ServiceRadar.DataCase` owner supplied to its test process. None starts a
database child process, so none needs `ServiceRadar.DataCase.allow_sandbox/1`.

## Promoted modules

| Source | Transaction and identifier evidence | Excluded shared-state behavior |
| --- | --- | --- |
| `test/integration/advisory_feed_loader_integration_test.exs` | Every loader read/write and the `on_exit` cleanup use the test's Repo owner. The `loader-itest-#{System.unique_integer(...)}` feed key scopes the provider/feed rows and coordinates to one test. | No unboxed mode, DDL, application mutation, external service, global database worker, or child process. |
| `test/integration/secret_broker_audit_integration_test.exs` | Provider, secret, and audit writes execute synchronously through the calling test transaction. The provider name, secret name, external reference, grant ID, and consumer ID include one `System.unique_integer/1` value. | No unboxed mode, DDL, application mutation, external service, global database worker, or child process. |
| `test/serviceradar/composite_checks/composite_check_test.exs` | Ash create/update calls execute in the DataCase transaction. Static names are only compared with rows written by the same transaction, and each parallel sandbox owner cannot observe another owner's uncommitted rows. | No unboxed mode, DDL, application mutation, external service, global database worker, or child process. |
| `test/serviceradar/composite_checks/composite_check_rule_test.exs` | Each `new_check/0` creates a check with a `System.unique_integer/1` name, and all rule writes/reads stay under the test owner. | No unboxed mode, DDL, application mutation, external service, global database worker, or child process. |
| `test/serviceradar/composite_checks/composite_check_input_test.exs` | Setup creates a check with a `System.unique_integer/1` name; input uniqueness is scoped to that check and all Ash work remains in the test transaction. | No unboxed mode, DDL, application mutation, external service, global database worker, or child process. |
| `test/serviceradar/composite_checks/device_composite_check_result_test.exs` | Setup creates a unique check per test. Reused device UIDs are only meaningful within that check and transaction; upsert/read/delete work remains under the calling owner. | No unboxed mode, DDL, application mutation, external service, global database worker, or child process. |

## Explicit serial decisions

| Source or lane | Reason it remains serial |
| --- | --- |
| Credential event writer | Mutates application environment to exercise the success-event flag. |
| Credential broker grant lifecycle | `setup_all` starts core and mutates application configuration. |
| Ordinary ResultsRouter | Mutates three application environment values for ingestion behavior. |
| First-user role assignment | Uses unboxed sandbox mode, `TRUNCATE`, and true multiple database connections. |
| Onboarding package atomicity | Uses unboxed mode, global crypto configuration, and lock-visibility behavior. |
| Remote access sessions | Mutates application configuration, uses task concurrency, and performs committed cleanup. |
| NetFlow ingestion | Uses a fixed external NATS resource and is pinned to the serial `s7` lane. |
| Ad-hoc scan NATS E2E | Uses a fixed external NATS resource and is pinned to the serial `s7` lane. |
| Proxmox smoke | Uses a fixed external resource and is pinned to the serial `s7` lane. |

Rollup and `RemoteAccessHostKeys` are intentionally outside this first wave and remain serial.
