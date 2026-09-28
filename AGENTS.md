<!-- OPENSPEC:START -->
# OpenSpec Instructions

These instructions are for AI assistants working in this project.

Always open `@/openspec/AGENTS.md` when the request:
- Mentions planning or proposals (words like proposal, spec, change, plan)
- Introduces new capabilities, breaking changes, architecture shifts, or big performance/security work
- Sounds ambiguous and you need the authoritative spec before coding

Use `@/openspec/AGENTS.md` to learn:
- How to create and apply change proposals
- Spec format and conventions
- Project structure and guidelines

Keep this managed block so 'openspec update' can refresh the instructions.

<!-- OPENSPEC:END -->

# Hard Rules (never violate)

- **Never commit data captured from a live system, and never let a real value
  become a fixture.** Every test fixture, example, doc snippet, README sample,
  seed CSV, decoder unit test and debugging artifact MUST be synthetic —
  invented from nothing, not exported from a running deployment and edited. This
  applies to production, staging, lab, demo and any customer or partner
  environment, and it applies to a value you pasted "just to reproduce a bug".

  This repository's `CLAUDE.md` tabulates the forbidden classes and their
  reserved replacements, and is the authority; it is not repeated here. The
  classes cover hostnames and internal naming schemes, site/facility codes, IPs
  and CIDRs, MAC addresses observed on a live system (an invented MAC may
  use a real vendor OUI), serials and asset tags, deployment
  build numbers, GPS coordinates from customer site records, phone numbers, people, namespaces and
  cluster/tenant/account names, policy/RADIUS/VLAN/SSID names, session and trace
  IDs, verbatim capture slices, and fleet-scale figures.

  **Removing the organization's name is not sufficient, and treating it as
  sufficient is the specific failure this rule exists to prevent.** A naming
  convention, a coordinate pair, a build number, a serial or a distinctive fleet
  shape identifies an organization on its own. When data turns out to be real,
  **regenerate the fixture from scratch** — do not search-and-replace it.
  Replacement preserves the shape, and the shape is the tell.

  Corollaries, each earned:
  - **A real value spreads.** One captured MAC became the canonical
    MAC-normalization fixture in three encodings across an unrelated test file.
    Fix the value at its source before it is copied.
  - **Non-test source counts.** Decoder unit tests, `README.md` examples and
    docs-site pages ship. A capture pasted into a decoder test is shipped
    product source, not a test artifact.
  - **Comments count.** Do not narrate a customer's outage, environment name, or
    ticket in a code comment. Describe the failure mode, not the site.
  - **A deleted branch does not unpublish a commit, and merging the scrubbed
    rewrite does not either.** GitHub keeps `refs/pull/<n>/head` after the branch
    is deleted and after the PR merges, so a commit pushed once stays fetchable
    by SHA — `gh api repos/<owner>/<repo>/commits/<sha>` resolves it and the web
    UI serves it. No history rewrite on your side can reach that ref. A clean
    `git grep` on `staging` therefore proves nothing about what is published;
    check `git branch -r --contains <sha>` and the PR head refs. Only the host
    can purge it.
  - **Downstream registries are immutable.** crates.io, `proxy.golang.org`, npm,
    hex.pm, an OCI registry or the published docs site **cannot be fixed by
    rewriting git history**. Check the fixture before the release, not after.
  - **Scrubbing quietly.** A commit message, branch name or PR title that names
    the affected party re-publishes exactly what the commit removes. Describe
    the change by class.
  - **Commit identity is content.** Author and committer email cannot be
    corrected without rewriting history. Verify `git config user.email` in every
    clone and worktree; a global identity survives a re-clone.

  **When searching for such data, anchor every pattern.** An organization
  abbreviation is usually a substring of ordinary English — here a bare
  three-letter match returned ~20,000 lines against ~480 real ones, matching
  `equal`, `manual`, `actual`, `virtual`, `toEqual` and `quality`. Prove a
  pattern does not over-match before feeding it to a bulk or history-rewriting
  tool.

  If you discover captured data already committed, do not quietly delete it:
  determine how far it spread first — other fixtures, published packages, PR
  head refs, the docs site, release tags — because the deletion is the easy half.

- **GitHub is the collaboration host for this repository.** Issues, pull requests,
  reviews and comments for `carverauto/serviceradar` go through `gh` against
  <https://github.com/carverauto/serviceradar>. The Forgejo instance at
  `code.carverauto.dev` is **retired for this repo** — do not link to it, clone from it,
  or file against it. Two consequences that bite:
  - **Forgejo issue/PR numbers do not map to GitHub numbers.** A doc citing "issue #4851"
    from the Forgejo era does not become GitHub #4851. Find the real GitHub equivalent or
    drop the link; never just swap the hostname.
  - Sibling repos moved too: `serviceradar-sdk-go` and `serviceradar-sdk-rust` are on
    GitHub (`github.com/carverauto/...`, which is what every `go.mod` already imports).
    `serviceradar-ansible`, `crm` and `serviceradar-control` remain on Forgejo, so
    references to those are correct as-is.

  Historical records keep their original references: the `CHANGELOG`, anything under
  `openspec/changes/archive/`, dated `docs/learnings/adlr/` entries, and test fixtures that
  deliberately exercise the Forgejo release path all describe what was true at the time.
  Rewriting them would falsify the record.

- **Never push directly to `staging` (or any shared/protected branch).** No
  `git push origin <ref>:refs/heads/staging`, no fast-forward push, no
  exceptions — not even when asked to "get this into staging." Land changes on a
  feature branch and open a pull request, or hand the `git push` to the user.
  Direct pushes to staging are unacceptable.
- **Always push with an explicit refspec: `git push origin <local>:refs/heads/<branch>`.**
  NEVER `git push origin <branch>` or `git push` — `push.default=upstream` plus a
  branch that tracks `origin/staging` (which `git worktree add -b <name> origin/staging`
  sets up) silently redirects the push to **staging**. Create feature worktrees with
  `git worktree add --no-track -b <name> origin/staging`, and verify the push line says
  `-> <name>`, never `-> staging`.
- **Cut releases with `scripts/cut-release.sh`.** Update `CHANGELOG` and `VERSION`
  first (the script validates a CHANGELOG entry for the version, and updates
  `VERSION`, `helm/serviceradar/Chart.yaml`, and the demo ArgoCD source). The
  user runs the release/push.
- **All metrics/telemetry flow through NATS JetStream first — never write metrics
  directly to the database.** Every metric source (interface/flow/OTEL metrics,
  SNMP counters, and sysmon cpu/mem/disk/process) MUST publish to a JetStream
  subject and be persisted by the `event_writer` consumer pipeline. CNPG remains
  the control-plane/current-state store. When StarRocks is enabled it is the ONLY
  telemetry store: EventWriter writes telemetry to StarRocks and not to CNPG, and
  telemetry readers read the warehouse, never a CNPG telemetry table (which stops
  receiving rows); when StarRocks is disabled, EventWriter writes telemetry to CNPG
  (see `openspec/changes/extend-starrocks-to-all-telemetry`, design Decision 1).
  Never both at once, and never neither: CNPG stays a complete telemetry backend
  for installations without StarRocks, so do not remove a CNPG telemetry writer,
  reader or table when adding its warehouse counterpart.
  Collectors and agents MUST NOT write metrics straight to CNPG or StarRocks, and
  core MUST NOT ingest a metric path that bypassed JetStream. The legacy
  agent→gateway→core gRPC `StreamStatus` path that writes sysmon metrics directly
  to the database is the one known exception, being migrated to JetStream (see
  `openspec/changes/add-causal-anomaly-detection`). MTR traces travel on
  `mtr.results.>` and are stored by the EventWriter `Mtr` processor; core
  publishes them and never writes them. Do not add new direct-to-DB
  metric writes. The reason is architectural, not stylistic: a metric that lands
  straight in a hypertable is invisible to every real-time consumer (anomaly
  detection, the causal engine) until it is queried back out. Keeping all metrics
  on JetStream first makes every stream subscribable.
- **Integration and device credentials use the unified CNPG credential model —
  never Kubernetes/Vault/Helm/env secrets.** Community strings, SNMPv3 users,
  UniFi / Proxmox / NetBox / Armis / plugin tokens, SSH-to-device keys, and
  anything else used to talk to a monitored device or a third-party integration
  MUST store encrypted material in `platform.network_credential_secrets` and be
  managed through the canonical credentials settings area. Credential rules are
  scoped bindings (provider, auth method, purpose, target query, edge scope) and
  remain the preferred path when credentials must be selected dynamically for a
  target or compiler. A typed consumer whose own record defines the scope, such
  as an SNMP profile, may reference a reusable credential directly.

  Do **not** add consumer-local plaintext/ciphertext columns or an untracked
  `credential_secret_id` shortcut. Any new direct reference requires an approved
  product contract, a restrictive foreign key, inclusion in the complete
  credential-usage inventory and guarded-deletion checks, and a navigable usage
  surface. Do **not** mark a device/integration descriptor `supports_rules: false`
  merely to hide it from the rule form.

  Kubernetes Secrets, OpenBao/Vault, Helm values, process environment, Docker
  secrets, and SPIFFE SVIDs are only for **ServiceRadar talking to itself**: CNPG,
  NATS, the Dgraph ACL credential, SPIFFE/mTLS between core/gateway/agent,
  registry pull, image signing, session/JWT keys. They are not a store for "the
  SNMP password for farm01".

  `network_credential_secrets` is the operator-facing inventory of reusable
  encrypted material; `network_credential_rules` controls where that material
  may be applied. A zero-rule credential can still be live because a typed
  consumer such as an SNMP profile references it. Existing rule-bound,
  standalone, and direct-bound credentials must remain manageable and continue
  working without secret re-entry while consumers migrate to the unified model.
  Historical note: PR #4677 chased Dialyzer counts with apply/opaque barriers and
  MapSet churn; it was fully reverted in #4679. Do not reintroduce that style.
- **Close the path that creates bad data before you delete it, and never trust a
  deletion you have not re-checked.** Deleting first looks like it worked and is
  not: on 2026-08-23 a phantom device (`169.254.0.1`, an APIPA address a switch
  reported on its own interface) was soft-deleted twice and came back both times.
  A sweep re-adopted the record as a target and revived it, and the revival
  cleared `deleted_reason`/`deleted_by` — so the cleanup left **no trace it had
  ever happened**, and the record was indistinguishable from one never deleted.

  Practical consequences, all of them earned:
  - **Find every writer, not the obvious one.** Three code paths clear a device
    tombstone: `Device` actions `:gateway_restore` and `:restore`, and a raw Ecto
    `on_conflict` in `inventory/sync/device_writes.ex` that never builds an Ash
    changeset. A guard placed in an Ash change module is blind to the third by
    construction. `grep` for the attribute, not for the action.
  - **Re-query after deleting**, and again after the job that creates the data
    has run. "The delete returned `{:ok, ...}`" is not evidence the row is gone.
  - Prefer an audit record that is **append-only**. An audit that can reject a
    write grows a bypass flag, and the bypass becomes the default.
  - Device revivals are now recorded: a trigger writes
    `platform.device_revival_audit` whenever `deleted_at` goes from set to NULL,
    capturing the `deleted_by`/`deleted_reason` the revival is about to destroy.
    If a deletion you made appears to have been undone, query that table by
    `device_uid` rather than re-deleting and hoping.

- **A verification must be able to FAIL, and you must read what it actually
  printed.** Three times in one session a check — not the system — was the broken
  thing, and each was one step from reporting a working fix as broken:
  a mapper job logged `success` with `last_run_interface_count=307` while writing
  **zero** rows (the count was stale from an earlier run); a monitor grepped
  `SyncIngestor result: {:ok` when the log emits a bare `:ok`, so its success
  counter could never fire; and a run at 21:53 was judged against pods that
  started at 21:57, so it could only ever reproduce the old behaviour.

  Before believing a green result:
  - **Gate on the artefact, not the job.** Query for rows written after the
    deploy, for the specific device — a partial run writes some and not others.
  - **Copy the real log line** out of the output before writing a pattern for it.
  - **Confirm the run started after the rollout finished.** Mid-rollout, old and
    new pods serve simultaneously and the old ones keep producing old behaviour.
  - **Give every check an explicit failure branch.** A check that can only
    confirm success is indistinguishable from one that is still waiting, which is
    how "no news" gets reported as "verified".

- **Use `ServiceRadar.HTTP.EgressClient` for external artifact downloads.** Its
  [module documentation](elixir/serviceradar_core/lib/serviceradar/http/egress_client.ex)
  owns the streaming contract and CONNECT-proxy compatibility rationale. The
  regression coverage is in
  `elixir/serviceradar_core/test/serviceradar/http/egress_client_test.exs`.

# Codex Agent Guide for ServiceRadar

This repository hosts the ServiceRadar monitoring platform. Use this file as the canonical guide when operating as a Codex agent.

## Project Overview

ServiceRadar is a multi-component system made up of Go services (core, sync, registry, agent, faker), a Rust-based SRQL service, CNPG/Timescale storage, a Next.js web UI, and supporting tooling. The repo contains Bazel and Go module definitions alongside Docker/Bazel image targets.

## Repository Layout

- `go/cmd/` – Go binaries (agent, cli, data-services, faker, tools).
- `go/pkg/` – Shared Go packages: identity map, registry, sync integrations, database clients.
- `rust/srql/` – SRQL translator/service backed by Diesel + CNPG.
- `docs/docs/` – User and architecture documentation (notably `architecture.md`, `data-pipeline.md`, `edge-model.md`).
- `helm/serviceradar/` – Supported Kubernetes installation chart for demo and production deployments.
- `docker/`, `docker/images/` – Container builds and push targets.
- `elixir/web-ng/` – Phoenix (next-gen) UI/API monolith.
- `proto/` – Protobuf definitions and generated Go code.

## Per-Directory Agent Guides

Before inspecting or editing a subtree, read its closest `AGENTS.md`; `elixir/web-ng/AGENTS.md` is mandatory for `elixir/web-ng/**`.

Before writing or changing any test, load the `test-audit` skill.

- **Bringing a database up to date: `mix serviceradar.db.migrate`, NOT `mix ecto.migrate`.**
  An empty database is built from the committed baseline and only newer migrations run;
  `mix ecto.migrate` replays every migration in the tree instead, which is slow and has
  failed outright against a remote instance. Pass `--no-baseline` only when you deliberately
  want the full replay. **The baseline does not work on a database that already carries
  TimescaleDB hypertables or AGE graphs, which is every real one** — the schema does not
  round-trip, so the fixture lifecycle replays on an empty database instead. Do not
  reintroduce baselining there; why it cannot work is in
  [docs/agent-runbooks.md](docs/agent-runbooks.md).
- Rust dep bump (cargo + Bazel in one go): `make update-rust-deps REPIN=workspace`, or `scripts/update-rust-bazel-deps.sh [update-mode] [verify-target]` — runs `cargo update` → `cargo check` → `bazel run //third_party/crate_mirror:sync` → `bazel build`. To only refresh the vendored archives after hand-editing the root `Cargo.toml`: `bazel run //third_party/crate_mirror:sync`. See [Rust Dependency Management](#rust-dependency-management).

Prefer Bazel targets when modifying code that already has BUILD files. Always run gofmt/cargo fmt where applicable (Go formatting handled by `gofmt`, Rust by `cargo fmt`).

## Socket Firewall

Prefer Socket Firewall for supported dependency-fetching commands. Prefix JavaScript/TypeScript package manager calls with `sfw`, especially `npm` commands such as `sfw npm ci`, `sfw npm install`, and `sfw npm run ...` when the command may fetch packages. Also use `sfw` for supported Python and Rust package managers (`pip`, `uv`, and `cargo`) when they may download dependencies. Web-NG uses Bun for asset builds; prefix Bun package-manager invocations with `sfw` in CI and Bazel release tooling as a best-effort firewall even though Socket Firewall Free only officially guarantees npm/yarn/pnpm for JavaScript. Socket Firewall Free does not currently support Go, Bazel, or Hex/Mix, so do not wrap those commands unless Socket adds support.

## Coding Guidelines

- **Go**: run `gofmt` on modified files; keep imports organized; favor existing helper utilities in `pkg/`. Avoid introducing new dependencies without updating `go.mod` and Bazel `MODULE.bazel`/`MODULE.bazel.lock` if required.
- **Rust**: run `cargo fmt` + `cargo clippy` on touched crates (notably `rust/srql`); leverage existing Diesel helpers + CNPG pooling utilities before adding new abstractions.
- **Docs**: place new operational runbooks under `docs/` root (alongside `agent-runbooks.md` and `cold-tier-runbook.md`), not under `docs/docs/` (that subtree is the published Docusaurus site); keep Markdown ASCII only.
- **Causal / statistical / streaming-anomaly reasoning**: use the **DeepCausality** library (`deep_causality_core` Flow API plus `deep_causality_data_structures` `SlidingWindow`; source at `~/src/deep_causality`), wrapped by the project-owned **`serviceradar-anomaly-core`** crate (`rust/anomaly-core`). DeepCausality is authored by Marvin Hansen, who guides ServiceRadar's anomaly-engine design. **Do not hand-roll a parallel detector** for rolling z-score, running mean/variance, sliding windows, CSM, or equivalent anomaly decisions in Elixir, Go, or a second Rust crate when `serviceradar-anomaly-core` already provides the primitive. A second implementation must be kept in numeric parity by hand and can drift. **`serviceradar-anomaly-core` is the single source of truth**: it powers the edge anomaly add-on (`rust/anomaly-addon`, agent-sidecar) today and a backfill/backtesting CLI. The legacy central `causal_reasoner_nif` + central analysis pipeline are **being retired** (per-series anomaly moved to the edge; see `openspec/changes/move-anomaly-detection-to-edge`) — do not extend them. If DeepCausality lacks a primitive, add it upstream or to `serviceradar-anomaly-core`, never a divergent reimplementation.

## Iron Laws

- **LiveView**: no database queries in disconnected mount. Use streams for lists larger than 100 items. Check `connected?/1` before PubSub subscribe.

## Operational Runbooks

Step-by-step procedures live in [docs/agent-runbooks.md](docs/agent-runbooks.md), so that
this file stays inside its context budget: demo namespace Helm refresh (including the
web-ng-only fast path), Docker Compose refresh, local development against Docker CNPG,
web-ng visual testing and remote dev, the local mTLS ERTS cluster, edge onboarding
testing, the release playbook, CNPG database access, and the SRQL fixture lifecycle.

## When Updating This File

- Add new build/test commands when tooling changes.
- Keep instructions synchronized with the latest bead notes and related documentation updates.
- If Bazel credentials or worktree setup change, keep the `.bazelrc.remote` hard rule accurate.

## Multitenancy Guardrails

ServiceRadar is single-deployment. Do not add multitenancy features, per-customer routing, or multitenancy bypass modes (`:bypass`, `:bypass_all`, `allow_global` overrides). Keep all access scoped to the deployment and schema defined by the database connection.

## Code Generation

Start with generators wherever possible. They provide a starting point for your code and can be modified if needed.

## Logs & Tests

After changes, compile and run applicable tests; read their output and report every check not run.

## Tools

Tidewave MCP tools are optional and may not always be available. Use them when present for deeper inspection, but proceed without them when unavailable.

