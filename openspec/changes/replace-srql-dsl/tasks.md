## 1. Rust SRQL translator
- [ ] 1.1 Finalize crate layout (workspace entry, Bazel targets, Docker image) and add Diesel plus CNPG connection pooling dependencies.
- [ ] 1.2 Port the SRQL parser/planner into Rust, exposing modules for parsing the DSL AST and translating it into Diesel query builders against CNPG schemas.
- [ ] 1.3 Implement the `/api/query` HTTP surface (mTLS + Kong-authenticated) that executes translated statements via Diesel, streams rows, and exposes metrics/logging.

## 2. DSL compatibility and migration
- [ ] 2.1 Define the updated SRQL syntax/semantics doc and add fixtures verifying parity for the dashboards/alerts that currently call the OCaml service.
- [ ] 2.2 Build feature flags/headers (core + web) that allow dual-running the OCaml and Rust translators, and gate rollouts on telemetry that compares results.
- [ ] 2.3 Remove or quarantine Proton-specific behaviors so implementations fail fast when unsupported operators are used.

## 3. Operational integration
- [ ] 3.1 Update architecture/docs/runbooks to describe the Rust service, CNPG connectivity, and local dev instructions.
- [ ] 3.2 Produce deployment manifests (Docker Compose + k8s demo) and CI tasks so the Rust SRQL binary builds, tests, and publishes images alongside other services.
- [ ] 3.3 Schedule and execute the cut-over plan (demo first, then prod), including removing the OCaml deployment, after the new service clears validation.
