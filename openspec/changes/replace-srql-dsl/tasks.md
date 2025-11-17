## 1. Rust SRQL translator
- [x] 1.1 Finalize crate layout (workspace entry, Bazel targets, Docker image) and add Diesel plus CNPG connection pooling dependencies.
- [x] 1.2 Port the SRQL parser/planner into Rust, exposing modules for parsing the DSL AST and translating it into Diesel query builders against CNPG schemas.
- [x] 1.3 Implement the `/api/query` HTTP surface (mTLS + Kong-authenticated) that executes translated statements via Diesel, streams rows, and exposes metrics/logging.

## 2. DSL compatibility and migration
- [ ] 2.1 Define the updated SRQL syntax/semantics doc and add fixtures verifying parity for the dashboards/alerts that currently call the OCaml service.
- [x] 2.2 Rip out the dual-run plumbing (configs, headers, env vars) so `/api/query` always targets the Rust translator and there is no path to re-enable the OCaml service. *(Rust server no longer instantiates the dual runner and the web/client configs only know about the CNPG backend.)*
- [x] 2.3 Remove or quarantine Proton-specific behaviors so implementations fail fast when unsupported operators are used. *(New Diesel executor rejects Proton-only fields and the UI now consumes canonical timestamp columns.)*

## 3. Operational integration
- [ ] 3.1 Update architecture/docs/runbooks to describe the Rust service, CNPG connectivity, and local dev instructions.
- [x] 3.2 Produce deployment manifests (Docker Compose + k8s demo) and CI tasks so the Rust SRQL binary builds, tests, and publishes images alongside other services. *(Compose now launches the Rust binary, Bazel builds the `rust/srql` image, and demo/prod overlays include the new Deployment wired to SHA-tagged pushes.)*
- [ ] 3.3 Schedule and execute the cut-over plan (demo first, then prod), including removing the OCaml deployment, after the new service clears validation.
