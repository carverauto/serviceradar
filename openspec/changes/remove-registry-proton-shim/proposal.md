# Change: Remove Proton-style registry compatibility shim

## Why
- The Proton migration spec promised that registry queries would run directly on CNPG/pgx, yet `pkg/registry` still routes every query and insert through `db.Conn`, a compatibility layer that rewrites `?` placeholders and emulates the Proton batch API (`pkg/db/db.go`).
- This shim is the last code path that references "Proton" inside `pkg/db` (`pkg/db/interfaces.go:34`), keeps the `Service` interface tied to legacy semantics, and makes it harder to reason about prepared statements or benefit from pgx features.
- Because the compatibility layer lives in `pkg/db`, any future schema work must understand both the typed CNPG helpers *and* the shimmed query flow, increasing maintenance risk.

## What Changes
- Remove `DB.Conn`/`CompatConn` from `pkg/db` and migrate every `pkg/registry` call site to typed helpers (`ExecCNPG`, `QueryCNPGRows`, or new helper methods dedicated to registry queries/events).
- Replace the `PrepareBatch` based insert for `service_registration_events` with a pgx `Batch` helper that works natively with `$n` placeholders and typed metadata marshaling.
- Update the `Service` interface/docs so it clearly describes CNPG responsibilities instead of Proton streams.
- Expand registry-focused unit tests/mocks so they cover the new helpers and prove no code depends on Proton-style placeholder rewriting.

## Impact
- Touches `pkg/db` and `pkg/registry`, so we must rerun the Bazel Go tests covering both packages.
- Slight refactors for callers that expected `db.Conn` to exist; mock generation may need updates after the interface changes.
- No user-facing behavior change is expected, but the cleanup removes the last Proton references inside the Go data layer and makes future schema or registry work easier.
