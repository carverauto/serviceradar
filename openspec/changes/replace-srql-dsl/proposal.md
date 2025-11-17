## Why
- The OCaml SRQL translator only speaks the legacy DSL that was tuned for Proton/ClickHouse semantics, and the Proton stacks are already being decommissioned.
- Maintaining OCaml/dune infrastructure for a single binary makes it hard to attract maintainers, integrate with the rest of the Rust-focused telemetry code, or reuse shared tooling.
- Query traffic is shifting to CNPG, and we currently have no documented or supported way to execute ServiceRadar queries against the CNPG device/timeseries schemas.

## What Changes
1. Design and implement a Rust-based SRQL translator/service that speaks the `/api/query` contract, uses Diesel.rs for query construction, and targets CNPG through pooled connections that respect SPIFFE/Kong authentication requirements.
2. Define the new SRQL DSL syntax/semantics so it maps onto CNPG schemas (devices, signals, aggregated metrics) and provides backward-compatible operators for the dashboards that today rely on the OCaml service.
3. Outline the migration story: dual-running strategy, toggles, telemetry/alerting so we can flip Kong/Core consumers over without downtime, plus documentation for running the Rust service locally and in demo/prod clusters.

## Impact
- New Rust crate/binary plus Docker/Bazel targets, Diesel dependency management (Go toolchain unaffected).
- Updates to docs (`architecture.md`, SRQL runbooks) and potentially Next.js/Core configs to point at the new service.
- Operational readiness work (metrics, logs, config) to support rollout plus removal plan for the OCaml code once the Rust DSL is fully vetted.
