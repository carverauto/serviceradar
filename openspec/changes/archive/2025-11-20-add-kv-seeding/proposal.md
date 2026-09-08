# Change: add-kv-seeding

## Why
Currently, `serviceradar` components do not automatically seed the KV store with their default configuration when starting up. This leads to missing configuration in environments like `demo-staging` and requires manual seeding. Additionally, we need a mechanism to ensure that while KV configuration overrides filesystem defaults, certain security-sensitive settings can be "pinned" to the filesystem and not overwritten by KV.

## What Changes
- **Automatic Seeding**: Every service will check the KV store on startup. If a configuration key is missing, it will seed it from a local default configuration file (e.g., `/etc/serviceradar/<component>.json`).
- **Configuration Precedence**:
    - **Defaults**: Loaded from filesystem (e.g., `config.default.json`).
    - **KV**: Overrides defaults via deep merge (nested objects preserved unless explicitly overridden).
    - **Pinned**: (Optional) Specific filesystem configuration that overrides KV via deep merge (e.g., `config.pinned.json` or specific keys), primarily for security-sensitive settings.
- **Atomic Seeding**: Services deep-merge defaults with any existing KV payload and use an atomic create to avoid races when multiple instances start together.
- **Configuration Observability**: The final merged configuration is emitted (with sensitive fields redacted) via startup logging and/or exposed through a read-only diagnostic endpoint.
- **Test Infrastructure**: A NATS JetStream container will be added to the Kubernetes test environment (outside `demo` namespaces) to support CI/CD integration tests for this behavior.

## Impact
- **Affected Specs**: `kv-configuration` (new capability).
- **Affected Code**:
    - Shared configuration libraries in Go (`pkg/config` or similar) and Rust (`rust/crates/config_bootstrap`).
    - Kubernetes manifests and Helm charts (to mount default config files).
    - CI/CD pipeline (new NATS fixture).

## Status / Next Steps
- Done: sr-testing NATS JetStream fixture (TLS + LoadBalancer) deployed; Bazel/BuildBuddy env wiring for NATS certs; integration tests covering packaged default seeding, KV-vs-default precedence, and deep-merge nested retention; Go/Rust bootstrap support for a pinned file overlay; Go/Rust config bootstraps now enforce Default -> KV -> Pinned precedence and seed missing KV entries automatically with atomic create.
- Done: Helm + kustomize defaults aligned to mount configs at `/etc/serviceradar/<component>.json`, db-event-writer mounts fixed for runtime copy flow.
- Done: CNPG operator/webhooks installed once per cluster (cnpg-system) so CNPG `Cluster` CRs reconcile while still pointing at our custom Postgres image; demo-staging apply is clean/idempotent and CNPG clusters untouched.
- Done: Added config observability via startup logging with sensitive-field redaction in Go bootstrap.
- Next: Optional read-only admin exposure of merged config (where appropriate) to complement logging.
