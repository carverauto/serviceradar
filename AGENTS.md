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
  and CIDRs, MACs with a real vendor OUI, serials and asset tags, deployment
  build numbers, GPS coordinates, phone numbers, people, namespaces and
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
- **After `git worktree add` (or any extra checkout), symlink the gitignored
  Bazel rc files before any `bazel` command.** `.bazelrc` try-imports
  `%workspace%/.bazelrc.remote` and `.bazelrc.local`. Both are gitignored:
  they hold the BuildBuddy API key and the remote cache/executor overrides.
  `git worktree add` only checks out tracked files, so a new worktree has
  neither. Without them `--config=remote` / `--config=ci` cannot authenticate:
  Bazel prints `PERMISSION_DENIED: Missing API key` and never reaches RBE
  (local crawl or abort). `bb view` still works from the primary clone — that
  is not proof the worktree is wired for remote execution. From the checkout
  that already has the files:

  ```
  ln -sfn "$PRIMARY/.bazelrc.remote" "$WT/.bazelrc.remote"
  test -e "$PRIMARY/.bazelrc.local" && ln -sfn "$PRIMARY/.bazelrc.local" "$WT/.bazelrc.local"
  test -f "$WT/.bazelrc.remote"
  ```

  Same rule for `/tmp/...` trees, `jj workspace add`, and extra clones. Never
  commit those files.
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
- **Never read generated Bazel output.** No `cp` out of `bazel-out`, no `bazel info
  bazel-bin` plus a path, no `bazel cquery --output=files` followed by reading the file. The
  output tree is a cache, not an interface: it can be wiped at any time, and its path encodes
  the configuration that produced it, so an artifact found under `bazel-out/rbe_platform-opt/`
  is whatever happened to be built with that platform and compilation mode — the same command
  with a different `-c` or `--config` silently reads something else, or nothing.

  This tree hides the path deliberately: `//.bazelrc` sets
  `--experimental_convenience_symlinks=clean`, so there is no `bazel-out` symlink at the
  workspace root. A copy that appears to do nothing there is that guard working. Do not route
  around it by resolving an absolute path by hand.

  Express the need as a target instead: a `filegroup` consumed as a declared input, or
  `write_source_files` from `aspect_bazel_lib` to copy an artifact back into the tree. When a
  generated file must be committed — protoc output embedded with `include_bytes!` so `cargo`
  works without Bazel, generated bindings — the pattern is a committed copy, a `diff_test`
  that says when it is stale, and a write-back target that makes it current. See
  `//config/manager_config/rust:update_embedded_instances`, which copies from runfiles. If a
  write-back target is missing, add one rather than doing the copy by hand.

- **Close the path that creates bad data before you delete it, and never trust a
  deletion you have not re-checked.** Deleting first looks like it worked and is
  not: on 2026-08-23 a phantom device (`169.254.0.1`, an APIPA address a switch
  reported on its own interface) was soft-deleted twice and came back both times.
  A sweep re-adopted the record as a target and revived it, and the revival
  cleared `deleted_reason`/`deleted_by` — so the cleanup left **no trace it had
  ever happened**, and the record was indistinguishable from one never deleted.

  Practical consequences, all of them earned:
  - **Find every writer, not the obvious one.** Three code paths clear a device
    tombstone: `Device` actions `:gateway_sync` and `:restore`, and a raw Ecto
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

- **No shell scripts. Everything is a Bazel target.** Do not add a script under
  `scripts/`, and do not extend an existing one. Build, test, provisioning, teardown,
  packaging and publishing are Bazel targets invoked with `bazel build` / `bazel test` /
  `bazel run`. A script is a build system with no dependency graph, no cache, no sandbox
  and no remote execution — every one of them is a hole in the graph that has to be
  re-run, re-debugged and re-documented by hand.

  **The only permitted exception is a hard corner case that genuinely cannot be a Bazel
  action**, and it must be justified in a comment at the top of the file. Today that means
  credential handling that must not become an action input: Docker/registry authentication
  and cosign/OpenBao signing setup, plus materializing rotating SRQL fixture credentials in
  the Bazel client's environment before database test actions start. "It was easier" is not
  a corner case.

  Corollaries:
  - Work an existing script does belongs in a target. `//rust/integration-db` already
    replaced `scripts/{reset,drop,sweep-stale-core}-test-db.sh` — those files are dead and
    should be deleted, not maintained.
  - A test needing a file gets it as a **declared input** (`data`/`srcs`), never from a
    script writing it to a runner temp dir and exporting a path. That pattern is what
    forces `no-remote-exec` and breaks RBE.
  - Ordering between targets is the caller's sequence of `bazel` invocations, not a script
    that wraps them.

- **Use `ServiceRadar.HTTP.EgressClient` for external artifact downloads.** Its
  [module documentation](elixir/serviceradar_core/lib/serviceradar/http/egress_client.ex)
  owns the streaming contract and CONNECT-proxy compatibility rationale. The
  regression coverage is in
  `elixir/serviceradar_core/test/serviceradar/http/egress_client_test.exs`.
- **Check the workspace Hex closure when Mix and release dependencies differ.**
  [The Hex build definition](third_party/hex/BUILD.bazel) owns the cross-project
  resolution policy; `third_party/hex/hex_packages.bzl` records the generated
  versions shipped by Bazel.

# Codex Agent Guide for ServiceRadar

This repository hosts the ServiceRadar monitoring platform. Use this file as the canonical guide when operating as a Codex agent.

## Project Overview

ServiceRadar is a multi-component system made up of Go services (core, sync, registry, agent, faker), a Rust-based SRQL service, CNPG/Timescale storage, a Next.js web UI, and supporting tooling. The repo contains Bazel and Go module definitions alongside Docker/Bazel image targets.

## Repository Layout

- `go/cmd/` – Go binaries (agent, cli, data-services, faker, tools).
- `go/pkg/` – Shared Go packages: identity map, registry, sync integrations, database clients.
- `rust/srql/` – SRQL translator/service backed by Diesel + CNPG.
- `docs/docs/` – User and architecture documentation (notably `architecture.md`, `agents.md`).
- `helm/serviceradar/` – Supported Kubernetes installation chart for demo and production deployments.
- `docker/`, `docker/images/` – Container builds and push targets.
- `elixir/web-ng/` – Phoenix (next-gen) UI/API monolith.
- `proto/` – Protobuf definitions and generated Go code.

## Per-Directory Agent Guides

This file applies repo-wide, but subdirectories may include their own `AGENTS.md` with more specific rules; always read and follow the closest one to the code you are editing.

- `elixir/web-ng/AGENTS.md` – Phoenix/Elixir/LiveView/Ecto/HEEx guidelines (must follow for any `elixir/web-ng/**` changes).

## Build & Test Commands

- **Every unit test, the way CI runs them: `make test`** — an alias for
  `bazel test -c opt --config=remote //... --test_tag_filters=-integration_test,-acceptance_test`.
  `--config=remote`, not `--config=ci`: the CI profile points its caches at `/bazel-cache`, the
  node volume only the BuildBuddy executors mount, so it cannot run on a workstation.
  **Run this before opening a PR and before cutting any release.** It is the only command
  that covers the whole repo, because the Elixir unit shards exist ONLY as bazel targets
  (`//elixir/serviceradar_core:unit_tests_*`, `//elixir/web-ng:unit_tests_*`) and are
  invisible to `go test`, `cargo test` and `mix test`. Two broken Elixir suites reached a
  release tag that way.
- Per-language tests + Go coverage profiles: `make test-toolchains` (go test / cargo test /
  vitest / `mix precommit`). Useful for a fast local loop; **not** a substitute for
  `make test`, and `make check-coverage` depends on it for the `cover.*.profile` files.
- Lint: `make lint`.
- Focused Go packages: `go test ./go/pkg/...`.
- SRQL (Rust) integration tests: `cd rust/srql && cargo test`.
- **Bringing a database up to date: `mix serviceradar.db.migrate`, NOT `mix ecto.migrate`.**
  An empty database is built from the committed baseline and only newer migrations run;
  `mix ecto.migrate` replays every migration in the tree instead, which is slow and has
  failed outright against a remote instance. Pass `--no-baseline` only when you deliberately
  want the full replay. **The baseline does not work on a database that already carries
  TimescaleDB hypertables or AGE graphs, which is every real one** — the schema does not
  round-trip, so the fixture lifecycle replays on an empty database instead. Do not
  reintroduce baselining there; why it cannot work is in
  [docs/agent-runbooks.md](docs/agent-runbooks.md).
- Bazel images: `bazel run //docker/images:<target>_push`. A worktree without
  `.bazelrc.remote` is not on RBE — copy the gitignored rc files first (Hard Rules).
- First-party Wasm plugins: `make build_wasm_plugins`, `make push_wasm_plugins`, `make verify_wasm_plugins`. Bazel fetches the pinned TinyGo toolchain automatically; local `oras` is still required for publish/inspect workflows. `make push_all` is the container-image path; `make push_all_release` adds the Wasm publish/sign/verify path for release-style runs.
- Rust dep bump (cargo + Bazel in one go): `make update-rust-deps REPIN=workspace`, or `scripts/update-rust-bazel-deps.sh [update-mode] [verify-target]` — runs `cargo update` → `cargo check` → `bazel run //third_party/crate_mirror:sync` → `bazel build`. To only refresh the vendored archives after hand-editing the root `Cargo.toml`: `bazel run //third_party/crate_mirror:sync`. See [Rust Dependency Management](#rust-dependency-management).
- Elixir workspace quality contract: `./scripts/elixir_quality.sh --project elixir/<project>` and add `--phoenix` for Phoenix apps such as `elixir/web-ng`. PRs gate `--lint-only` (format + Credo); the rest of the Mix contract runs daily from `//buildbuddy.yaml`.

Prefer Bazel targets when modifying code that already has BUILD files. Always run gofmt/cargo fmt where applicable (Go formatting handled by `gofmt`, Rust by `cargo fmt`).

Two registration gates fail **only** under `make test`/BazelCI — never under `mix test`,
`go test`, `cargo test` or a PR check — so a missing entry looks green all the way to
trunk:

- **Adding or changing a native add-on** (`addons/<name>/` + a Go/Rust binary) must be
  registered in four places, and any change to its source, config or `BUILD.bazel`
  requires bumping `addons/<name>/addon.yaml` `version`.
- **Adding an `elixir/serviceradar_core` test file** requires a row in
  `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`.

Both procedures, with their local verification commands, are in
[docs/agent-runbooks.md](docs/agent-runbooks.md).

## Socket Firewall

Prefer Socket Firewall for supported dependency-fetching commands. Prefix JavaScript/TypeScript package manager calls with `sfw`, especially `npm` commands such as `sfw npm ci`, `sfw npm install`, and `sfw npm run ...` when the command may fetch packages. Also use `sfw` for supported Python and Rust package managers (`pip`, `uv`, and `cargo`) when they may download dependencies. Web-NG uses Bun for asset builds; prefix Bun package-manager invocations with `sfw` in CI and Bazel release tooling as a best-effort firewall even though Socket Firewall Free only officially guarantees npm/yarn/pnpm for JavaScript. Socket Firewall Free does not currently support Go, Bazel, or Hex/Mix, so do not wrap those commands unless Socket adds support.

## Coding Guidelines

- **Go**: run `gofmt` on modified files; keep imports organized; favor existing helper utilities in `pkg/`. Avoid introducing new dependencies without updating `go.mod` and Bazel `MODULE.bazel`/`MODULE.bazel.lock` if required.
- **Rust**: run `cargo fmt` + `cargo clippy` on touched crates (notably `rust/srql`); leverage existing Diesel helpers + CNPG pooling utilities before adding new abstractions.
- **Elixir / Dialyzer**: prefer idiomatic Elixir (`MapSet.new/1`, direct `GRPC.Stub.connect/2`, normal Ash reads). Treat Dialyzer as advisory for false positives (opaque types, incomplete PLT success typing). See **Hard Rules** — never degrade APIs to silence the type checker. Use `mix dialyzer --format dialyzer` when Dialyxir short format crashes on unknown warning kinds.
- **Docs**: place new operational runbooks under `docs/docs/`; keep Markdown ASCII only.
- **OpenSpec**: See [Requirement Wording](openspec/AGENTS.md#requirement-wording)
  for the SHALL/MUST positional validation rule and examples.

  **Editing a requirement in `openspec/specs/` is not enough.** A pending change
  under `openspec/changes/` may carry its own `## MODIFIED Requirements` copy of
  the same `### Requirement:` block, and archiving that change replays its copy
  over `specs/` -- silently restoring the wording you just removed, with nothing
  in the archive step to flag the conflict. Before amending a requirement, run
  `grep -rn "<the exact bullet>" openspec/` and fix every pending delta that
  repeats it. Leave the copies under `openspec/changes/archive/` alone: they
  record what was true at the time, and rewriting them falsifies the record.
- **Causal / statistical / streaming-anomaly reasoning**: use the **DeepCausality** library (`deep_causality_core` Flow API plus `deep_causality_data_structures` `SlidingWindow`; source at `~/src/deep_causality`), wrapped by the project-owned **`serviceradar-anomaly-core`** crate (`rust/anomaly-core`). DeepCausality is authored by Marvin Hansen, who guides ServiceRadar's anomaly-engine design. **Do not hand-roll a parallel detector** for rolling z-score, running mean/variance, sliding windows, CSM, or equivalent anomaly decisions in Elixir, Go, or a second Rust crate when `serviceradar-anomaly-core` already provides the primitive. A second implementation must be kept in numeric parity by hand and can drift. **`serviceradar-anomaly-core` is the single source of truth**: it powers the edge anomaly add-on (`rust/anomaly-addon`, agent-sidecar) today and a backfill/backtesting CLI. The legacy central `causal_reasoner_nif` + central analysis pipeline are **being retired** (per-series anomaly moved to the edge; see `openspec/changes/move-anomaly-detection-to-edge`) — do not extend them. If DeepCausality lacks a primitive, add it upstream or to `serviceradar-anomaly-core`, never a divergent reimplementation.

## Rust Dependency Management

Full detail, with the reasoning behind each rule: **`rust/README_RUST.md`**. The traps
below are the ones an agent hits by accident.

- **Every dependency version lives in `[workspace.dependencies]` in the root `Cargo.toml`**,
  alphabetically sorted. A crate under `/rust/` NEVER names a version — it uses
  `{ workspace = true, features = [...] }`. Cargo and Bazel both read this one list, which
  is what keeps the two builds from drifting. (`sha2` in `rust/srql` is a documented
  exception; `rust/rdp-connector-probe` is deliberately detached.)
- **A green `cargo check` does NOT prove the Bazel build.** Finish every dependency change
  with `bazel build //rust/...`, and use `cargo check --workspace --lib --bins --tests` —
  plain `cargo check` skips test code that Bazel compiles.
- **`cargo check -p <crate>` must pass standalone.** Workspace feature unification hides a
  missing `features = [...]` behind another crate that enabled it.
- **`default-features = false` is only safe when the compiler catches the loss.** A dropped
  default that is a *runtime* backend compiles clean and fails in production — this exact
  mistake removed `ureq`'s TLS transport.
- **Refresh the vendored archives only with `bazel run //third_party/crate_mirror:sync`.**
  Source patches are `crate.annotation` `patches` entries applied at fetch time, so they
  are declared build inputs, not edits to a tree on disk.
- **OpenSSL comes from the `@openssl` BCR module** — never a vendored `openssl-src` build
  and never the machine's. Keep the `openssl-sys`/`pq-src` pairing in `//MODULE.bazel`, and
  set `OPENSSL_LIB_DIR`/`OPENSSL_INCLUDE_DIR` explicitly: `openssl-sys` reads them before
  `OPENSSL_DIR`, so the RBE executor's own OpenSSL gets linked silently otherwise.
- **`pq-src` is patched and pinned** (`pq-sys = "=0.7.5"`, patch in
  `//third_party/rust_patches/`). A bump that invalidates the patch fails the fetch loudly —
  do not paper over it; the patch is macOS-only, so skipping it leaves Linux CI green and
  breaks a developer's machine later.
- **Pass `cargo_only = True` to `all_crate_deps`**, and add the `@crates//:<name>` label by
  hand in any `BUILD.bazel` that lists deps explicitly — Bazel will not infer that one.
- **`rust_test(crate = ":x")` does NOT inherit `crate_features`** — repeat them, or the test
  compiles a different crate than the one that ships.
- **Every crate with `#[cfg(test)]` code needs a `rust_test` target.** flowgger silently
  carried a 2016 `serde_json` and fully broken config parsing because nothing ran its tests.

## Iron Laws

- **LiveView**: no database queries in disconnected mount. Use streams for lists larger than 100 items. Check `connected?/1` before PubSub subscribe.
- **Ecto**: never use `:float` for money. Always pin values with `^` in queries. Use separate queries for `has_many`, `JOIN` for `belongs_to`.
- **Oban**: jobs must be idempotent. Args use string keys. Never store structs in args.
- **Security**: no `String.to_atom/1` with user input. Authorize in every LiveView `handle_event`. Never use `raw/1` with untrusted content.
- **OTP**: no process without a runtime reason. Supervise all long-lived processes.
- **Elixir**: declare `@external_resource` for compile-time files. Wrap third-party library APIs behind project-owned modules. Never use `assign_new` for values refreshed every mount.

## Operational Runbooks

Step-by-step procedures live in [docs/agent-runbooks.md](docs/agent-runbooks.md), so that
this file stays inside its context budget: demo namespace Helm refresh (including the
web-ng-only fast path), Docker Compose refresh, local development against Docker CNPG,
web-ng visual testing and remote dev, the local mTLS ERTS cluster, edge onboarding
testing, the release playbook, CNPG database access, and the SRQL fixture lifecycle.

Architecture and data-pipeline background is in `docs/docs/` — `architecture.md`,
`data-pipeline.md`, `edge-model.md`. (Earlier revisions of this file pointed at
`docs/docs/agents.md`, which does not exist; `openspec/project.md` still cites it.)

## Common Commands & Tips

- Check demo pods: `kubectl get pods -n demo`.
- Scale sync: `kubectl scale deployment/serviceradar-sync -n demo --replicas=<n>`.
- GH client is installed and authenticated
- 'bb' (BuildBuddy) client is available for any build issues. `bb view`
  does not need `.bazelrc.remote`; `bazel --config=ci` / `--config=remote` does.
- bazel is our build system, we use it to build and push images. Isolated
  checkouts must symlink `.bazelrc.remote` from the primary clone or they
  never hit RBE (Hard Rules).
- Sysmon-vm hostfreq sampler buffers ~5 minutes of 250 ms samples; keep gateways querying at least once per retention window so cached CPU data stays fresh.

## When Updating This File

- Add new build/test commands when tooling changes.
- Keep instructions synchronized with the latest bead notes and related documentation updates.
- If Bazel credentials or worktree setup change, keep the `.bazelrc.remote` hard rule accurate.

## Ash First

Always use Ash concepts, almost never Ecto concepts directly. Think hard about the "Ash way" to do things. If you don't know, look for information in the rules & docs of Ash & associated packages.

When a change must remain atomic, implement `atomic/3` or refactor the action to stay atomic. Do not use `require_atomic? false` to silence atomicity warnings.

Ash rebuilds atomic updates from a second changeset. Put compare-and-set filters on the
pending caller changeset, not in an action-level `change filter(...)`. When `change/3`
registers an `after_action` hook, `atomic/3` must return `{:ok, change(changeset, opts,
context)}` rather than bare `:ok`. In an atomic callback, read proposed values from
`changeset.atomics` or `Ash.Changeset.fetch_change/2`; `Ash.Changeset.get_attribute/2`
can return old data or raise when original data is unavailable.

## Multitenancy Guardrails

ServiceRadar is single-deployment. Do not add multitenancy features, per-customer routing, or multitenancy bypass modes (`:bypass`, `:bypass_all`, `allow_global` overrides). Keep all access scoped to the deployment and schema defined by the database connection.

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

## Code Generation

Start with generators wherever possible. They provide a starting point for your code and can be modified if needed.

## Logs & Tests

When you're done executing code, try to compile the code, and check the logs or run any applicable tests to see what effect your changes have had.

## Tools

Tidewave MCP tools are optional and may not always be available. Use them when present for deeper inspection, but proceed without them when unavailable.

## SRQL Fixture Integration Tests

Use the `srql-fixtures-db-tests` skill when `elixir/serviceradar_core` integration tests
need the shared CNPG/AGE fixture. There is deliberately no orchestration script — you
invoke the guarded Bazel lifecycle in order, as the caller:
`sweep -> provision base -> migrate run if pending -> provision lanes -> test -> teardown`.

**Never migrate the shared template from a branch.** `sr_core_template` is shared by every
run on the fixture and only ratchets forward, so migrating it from a branch checkout writes
that branch's unmerged migrations into the schema every other branch clones — and then
refuses every checkout that lacks them. That is not hypothetical: one branch left seven
behind and turned every other pull request red on a step unrelated to its own diff. The
three targets that write it (`//elixir/serviceradar_core:migrate_template`,
`//rust/integration-db:prepare_template`, `//rust/integration-db:reset_template`) refuse
without `--//build:template_authority=true`, which only the trunk `LargeIngestionGate`
passes. Do not add that flag to get past a refusal — it is the caller declaring "this
checkout is trunk", not a way to unblock a step. A branch's own migrations belong in its
run base instead.

Full command sequence, sharding, run-id and credential rules, BazelCI merge-tree caveat and
cleanup checks: [docs/agent-runbooks.md](docs/agent-runbooks.md).
