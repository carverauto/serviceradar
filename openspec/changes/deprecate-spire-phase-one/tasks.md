## 1. Proposal and ownership

- [x] 1.1 Obtain approval of the phase-one proposal and compatibility contract (user approval via Lavish, 2026-10-08).
- [x] 1.2 Cross-reference the pending gateway proposal and notify the coordinator; preserve URI SAN identity behavior and leave unowned proposal edits to its owner.

## 2. Helm compatibility

- [x] 2.1 Add optional neutral service account and trust-domain keys, shared resolvers and compatibility documentation.
- [x] 2.2 Apply account resolution consistently to workloads, RBAC, allow-lists and SPIRE registration.
- [x] 2.3 Define effective CNPG settings and safe neutral override precedence without changing legacy cluster/secret identities by default.
- [x] 2.4 Add deprecation NOTES for explicit SPIRE/Workload API modes and change blank core datasvc security fallback to mTLS.
- [x] 2.5 Add executable Helm tests for default/legacy/mixed overrides and the related CNPG jobs.

## 3. Runtime and onboarding

- [x] 3.1 Add WARN-level deprecation logs to all effective Go/Rust/Elixir SPIFFE or Workload API startup paths using existing loggers.
- [x] 3.2 Test warning emission without real credentials or a live Workload API, and verify mTLS/filesystem starts do not warn.
- [x] 3.3 Change new-package defaults in Ash, the DB default migration, API and CLI to mTLS without rewriting existing rows.
- [ ] 3.4 Prove omitted defaults and explicit SPIRE compatibility through public callers and hosted database tests.

## 4. Documentation and delivery

- [x] 4.1 Mark current docs and openspec/project.md deprecated; add the migration guide with database verification and manual cleanup steps.
- [x] 4.2 Preserve historical records and all out-of-scope certificate URI/SRQL/env identity names.
- [x] 4.3 Run focused remote tests, docs lint, strict OpenSpec validation, formatting/quality checks and full make test.
- [x] 4.4 Upload the validated architecture diagram and portable OpenSpec review, retaining their source and evidence.
- [ ] 4.5 Submit the phase-one PR to staging through no-mistakes without --yes, link sr-5413, and record current-head CI. Reference phase one of #5413 without prematurely closing the remaining phases.
