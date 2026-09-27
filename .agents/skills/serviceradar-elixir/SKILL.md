---
name: serviceradar-elixir
description: Use for ServiceRadar Elixir, Phoenix, LiveView, Ash/Ecto, migrations, external downloads, Hex dependencies, formatting, or Dialyzer work.
user-invocable: false
metadata:
  internal: true
---

# ServiceRadar Elixir Rules

## Database migration command

- **Bringing a database up to date: `mix serviceradar.db.migrate`, NOT `mix ecto.migrate`.**
  An empty database is built from the committed baseline and only newer migrations run;
  `mix ecto.migrate` replays every migration in the tree instead, which is slow and has
  failed outright against a remote instance. Pass `--no-baseline` only when you deliberately
  want the full replay. **The baseline does not work on a database that already carries
  TimescaleDB hypertables or AGE graphs, which is every real one** — the schema does not
  round-trip, so the fixture lifecycle replays on an empty database instead. Do not
  reintroduce baselining there; why it cannot work is in
  [docs/agent-runbooks.md](docs/agent-runbooks.md).

## Quality commands

- Elixir workspace quality contract: `./scripts/elixir_quality.sh --project elixir/<project>` and add `--phoenix` for Phoenix apps such as `elixir/web-ng`. PRs gate `--lint-only` (format + Credo); the rest of the Mix contract runs daily from `//buildbuddy.yaml`.
- Same format/Credo check, hermetic on RBE and needing no local Hex `deps/`: `bazel test --config=remote //build/elixir_quality:quality_check`; auto-fix with `bazel run --config=remote //build/elixir_quality:format`. See `build/elixir_quality.bzl` for how Mix inputs are supplied.

- **Elixir / Dialyzer**: prefer idiomatic Elixir (`MapSet.new/1`, direct `GRPC.Stub.connect/2`, normal Ash reads). Treat Dialyzer as advisory for false positives (opaque types, incomplete PLT success typing). See **Hard Rules** — never degrade APIs to silence the type checker. Use `mix dialyzer --format dialyzer` when Dialyxir short format crashes on unknown warning kinds.

## Dialyzer

- **Never degrade production code to silence Dialyzer (or similar type checkers).**
  Idiomatic, readable APIs beat warning-count optimization. Do **not** introduce
  runtime shape hacks, opacity barriers, or non-idiomatic call patterns whose only
  purpose is to make Dialyzer happy. Forbidden patterns include (non-exhaustive):
  - `:erlang.apply(MapSet, :new, …)` / `apply(Mod, :fun, …)` / variable-module
    `apply` solely to hide success typing
  - “opaque_call” / 0-arity fun wrappers / `:erlang.binary_to_term(term_to_binary(…))`
    barriers around otherwise normal calls
  - Rewriting clear `MapSet` / `URI` / gRPC / Ash call sites into obscure forms to
    dodge opaque-type or error-only success typing noise
  - Broad “fix everything Dialyzer mentions” sweeps that churn APIs without a
    product or correctness win

  **Allowed approaches, in order:**
  1. Fix a real bug or wrong typespec with a clean, idiomatic change (and tests
     when behavior changes).
  2. Leave a false positive alone, or add a **narrow, documented** entry in the
     project’s `.dialyzer_ignore.exs` (file + warning kind or short description —
     never directory-wide suppressions).
  3. If Dialyxir cannot render a warning kind (e.g. `:opaque_compare`), report or
     work around the **formatter**, do not reshape application code for it.

  Historical note: PR #4677 chased Dialyzer counts with apply/opaque barriers and
  MapSet churn; it was fully reverted in #4679. Do not reintroduce that style.

## External downloads and dependencies

- **Use `ServiceRadar.HTTP.EgressClient` for external artifact downloads.** Its
  [module documentation](elixir/serviceradar_core/lib/serviceradar/http/egress_client.ex)
  owns the streaming contract and CONNECT-proxy compatibility rationale. The
  regression coverage is in
  `elixir/serviceradar_core/test/serviceradar/http/egress_client_test.exs`.
- **Check the workspace Hex closure when Mix and release dependencies differ.**
  [The Hex build definition](third_party/hex/BUILD.bazel) owns the cross-project
  resolution policy; `third_party/hex/hex_packages.bzl` records the generated
  versions shipped by Bazel.

## Iron Laws

- **LiveView**: no database queries in disconnected mount. Use streams for lists larger than 100 items. Check `connected?/1` before PubSub subscribe.
- **Ecto**: never use `:float` for money. Always pin values with `^` in queries. Use separate queries for `has_many`, `JOIN` for `belongs_to`.
- **Oban**: jobs must be idempotent. Args use string keys. Never store structs in args.
- **Security**: no `String.to_atom/1` with user input. Authorize in every LiveView `handle_event`. Never use `raw/1` with untrusted content.
- **OTP**: no process without a runtime reason. Supervise all long-lived processes.
- **Elixir**: declare `@external_resource` for compile-time files. Wrap third-party library APIs behind project-owned modules. Never use `assign_new` for values refreshed every mount.

## Ash First

Always use Ash concepts, almost never Ecto concepts directly. Think hard about the "Ash way" to do things. If you don't know, look for information in the rules & docs of Ash & associated packages.

When a change must remain atomic, implement `atomic/3` or refactor the action to stay atomic. Do not use `require_atomic? false` to silence atomicity warnings.

Ash rebuilds atomic updates from a second changeset. Put compare-and-set filters on the
pending caller changeset, not in an action-level `change filter(...)`. When `change/3`
registers an `after_action` hook, `atomic/3` must return `{:ok, change(changeset, opts,
context)}` rather than bare `:ok`. In an atomic callback, read proposed values from
`changeset.atomics` or `Ash.Changeset.fetch_change/2`; `Ash.Changeset.get_attribute/2`
can return old data or raise when original data is unavailable.

## Database Schema Management

**CRITICAL:** All database schema changes (tables, views, indexes, materialized views, extensions) MUST be managed exclusively through Elixir migrations in `elixir/serviceradar_core/priv/repo/migrations/`.

**CRITICAL:** All tables, indexes, and constraints belong in the `platform` schema. Do not create or reference objects in the `public` schema. In migrations, set `prefix: "platform"` for new tables/indexes/constraints and avoid `prefix: "public"` in references.

Ingestion services must NEVER create database schema or run DDL statements. They
write to existing tables but do not create or modify schema.

This rule exists because:
- Elixir migrations provide a single source of truth for schema
- Ecto migrations support up/down rollbacks and version tracking
- Having schema scattered across Go and Elixir creates maintenance nightmares
- Ingestion services may be replaced or scaled differently than schema management

If you need a new table, view, or materialized view that ingestion will write to,
create the migration in Elixir first.
