## Why
- The new Rust-based SRQL translator now owns the `/api/query` surface, but it shipped with only manual QA and a couple of unit tests that stop at the parser boundary.
- Without regression tests that exercise the DSL end-to-end (from HTTP payload → translator → CNPG row set), we cannot confidently evolve operators or refactor the Diesel plans.
- Dashboards and automation lean on SRQL as their query DSL; shipping without automated coverage means we risk silently breaking filters, aggregations, or error codes during routine refactors.

## What Changes
1. Build a deterministic SRQL API test harness around the Rust service that spins up against a seeded Postgres/CNPG schema so `/api/query` calls can be executed inside `cargo test` (or equivalent Bazel target).
2. Capture canonical DSL scenarios—inventory filters, aggregations, ordering/limits—and assert that `/api/query` responses (rows + metadata) match golden fixtures so any regression fails fast.
3. Add negative-path coverage for bad DSL, malformed JSON, and auth failures to confirm the API returns 400/401 responses instead of panicking, and publish run instructions so CI and local contributors run the suite.
4. Layer translator-level unit tests that exercise the SRQL language semantics described in `docs/docs/srql-language-reference.md` (filters, entity selectors, sorting, availability flags, etc.) so example queries like `in:devices time:last_7d sort:last_seen:desc limit:20 is_available:true` are locked down independent of the HTTP harness.

## Impact
- Introduces a seeded database fixture plus helper utilities for spinning up the SRQL server inside integration tests.
- Adds new cargo/Bazel test targets that CI must execute (slower test runtime but required for coverage).
- Requires documentation updates (README or docs/docs/agents.md) so contributors know how to run the SRQL API tests locally before submitting PRs.
