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

  The classes below are forbidden in the repository when they are **real**. Use
  the reserved/documentation alternative in parentheses:
  - Hostnames, FQDNs, and any internal naming scheme — device, controller,
    switch, AP, closet, site or rack names (`host01.example.com`, `SITE01-...`)
  - Site, region, facility, airport or datacenter codes; the *scheme* counts,
    not just the label
  - IP addresses and CIDR blocks, including RFC1918 ranges belonging to someone
    else's network plan (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`)
  - MAC addresses with a real vendor OUI (`00:00:5e:00:53:xx`)
  - Hardware serial numbers, asset tags, chassis IDs, manufacturing dates
  - Exact firmware/software build numbers tied to a deployment
  - GPS coordinates that resolve to a real facility (`0.0, 0.0`)
  - Telephone numbers, including NOC and on-call lines (`555-0100`–`555-0199`)
  - Person names, email addresses, usernames, employee or badge IDs
  - Kubernetes namespaces, cluster names, tenant IDs, workspace names,
    integration instance names, and account identifiers
  - Policy, AAA/802.1X, RADIUS, VLAN, SSID and firewall-rule names
  - Session IDs, syslog captures, packet captures, trace IDs, and any verbatim
    slice of a real event stream
  - Fleet scale figures (device counts, site counts, port counts) that describe
    a real estate

  **Removing the organization's name is not sufficient, and treating it as
  sufficient is the specific failure this rule exists to prevent.** A scrub that
  strips the label and keeps the fingerprint leaves the data fully attributable:
  a naming convention, a coordinate pair, a firmware build number, a serial, or
  a distinctive fleet shape identifies an organization on its own. When data
  turns out to be real, **regenerate the fixture from scratch** — do not
  search-and-replace it. Replacement preserves the shape, and the shape is the
  tell.

  Corollaries, each earned:
  - **A real value spreads.** One captured MAC became the canonical
    MAC-normalization fixture in three encodings across an unrelated test file.
    Fix the value at its source before it is copied.
  - **Non-test source counts.** Decoder unit tests, `README.md` examples and
    docs-site pages ship. A capture pasted into a decoder test is shipped
    product source, not a test artifact.
  - **Comments count.** Do not narrate a customer's outage, environment name, or
    ticket in a code comment. Describe the failure mode, not the site.
  - **Downstream registries are immutable.** Content that reaches crates.io,
    `proxy.golang.org`/`sum.golang.org`, npm, hex.pm, an OCI registry, or a
    published docs site **cannot be recalled by rewriting git history**. A
    version is permanent; yank and retract only discourage selection. Treat any
    publish as irreversible, and check the fixture before the release, not after.
  - **Scrubbing quietly.** A commit message, branch name, or PR title that names
    the affected party re-publishes exactly what the commit removes. Describe the
    change by class.
  - **Commit identity is content.** Author and committer email are baked into
    every commit and cannot be corrected without rewriting history. Verify
    `git config user.email` in every clone and worktree; a global identity is
    inherited by a fresh clone, so re-cloning does not fix it.

  **When searching for such data, anchor every pattern.** An organization
  abbreviation is usually a substring of ordinary English — in this repository a
  bare three-letter match returned ~20,000 lines against ~480 real ones, because
  it matched `equal`, `manual`, `actual`, `virtual`, `toEqual` and `quality`. An
  unanchored expression fed to a history-rewriting tool corrupts every commit at
  once, unreviewably. Use word boundaries or a qualifying delimiter, and prove
  the pattern does not over-match before running it.

  If you discover captured data already committed, do not quietly delete it:
  determine how far it spread first — other fixtures, published packages, the
  docs site, release tags — because the deletion is the easy half.

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
  subject and be persisted into CNPG by the `event_writer` consumer pipeline.
  Collectors and agents MUST NOT write metrics straight to CNPG, and core MUST NOT
  ingest a metric path that bypassed JetStream. The legacy agent→gateway→core gRPC
  `StreamStatus` path that writes sysmon metrics directly to the database is the
  one known exception, being migrated to JetStream (see
  `openspec/changes/add-causal-anomaly-detection`); do not add new direct-to-DB
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
  NATS, SPIFFE/mTLS between core/gateway/agent, registry pull, image signing,
  session/JWT keys. They are not a store for "the SNMP password for farm01".

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
  An empty database is built from the committed baseline
  (`elixir/serviceradar_core/priv/repo/baseline/`) and the migrations it contains are recorded
  as applied; only newer ones run. `mix ecto.migrate` replays all 436 migrations instead, which
  is slow and against a remote instance has failed outright. Pass `--no-baseline` only when you
  deliberately want the full replay. Service startup has always baselined; this task is the same
  code path (`ServiceRadar.Repo.SchemaBootstrap`).

  **The baseline does NOT work for a database that already carries TimescaleDB hypertables or
  AGE graphs, which is every real one.** It is a `pg_dump --schema-only`, and this schema does
  not round-trip: the dump contains 177 references into `_timescaledb_internal`
  (`_compressed_hypertable_45`, `_direct_view_23` -- names carrying the SOURCE database's OIDs)
  and 42 statements reproducing AGE's per-graph storage. Replaying those is not just privileged,
  it is wrong: `create_hypertable()` and `create_graph()` register objects in catalogs that plain
  DDL never touches, so the result holds graph tables `ag_catalog.ag_graph` has no row for. See
  `rust/integration-db/src/template.rs`, which states the non-round-trip property directly.
  The fixture lifecycle therefore REPLAYS on an empty database
  (`elixir/serviceradar_core/test/db/migrate_db_test.exs`) -- one slow run per template rebuild,
  paid by trunk, after which every run applies only what is pending. Do not reintroduce
  baselining there. `ServiceRadar.Cluster.StartupMigrations` still baselines a fresh deployment
  and has the same latent problem; that path is not yet fixed.
- Bazel images: `bazel run //docker/images:<target>_push`. A worktree without
  `.bazelrc.remote` is not on RBE — copy the gitignored rc files first (Hard Rules).
- First-party Wasm plugins: `make build_wasm_plugins`, `make push_wasm_plugins`, `make verify_wasm_plugins`. Bazel fetches the pinned TinyGo toolchain automatically; local `oras` is still required for publish/inspect workflows. `make push_all` is the container-image path; `make push_all_release` adds the Wasm publish/sign/verify path for release-style runs.
- Rust dep bump (cargo + Bazel in one go): `make update-rust-deps REPIN=workspace`, or `scripts/update-rust-bazel-deps.sh [update-mode] [verify-target]` — runs `cargo update` → `cargo check` → `bazel run //third_party/crate_mirror:sync` → `bazel build`. To only refresh the vendored archives after hand-editing the root `Cargo.toml`: `bazel run //third_party/crate_mirror:sync`. See [Rust Dependency Management](#rust-dependency-management).
- Elixir workspace quality contract: `./scripts/elixir_quality.sh --project elixir/<project>` and add `--phoenix` for Phoenix apps such as `elixir/web-ng`. PRs gate `--lint-only` (format + Credo); the rest of the Mix contract runs daily from `//buildbuddy.yaml`.

Prefer Bazel targets when modifying code that already has BUILD files. Always run gofmt/cargo fmt where applicable (Go formatting handled by `gofmt`, Rust by `cargo fmt`).

### Adding or changing a native add-on

A first-party native add-on (`addons/<name>/addon.yaml` + a Go/Rust binary) must be registered in **every** place CI enforces, or a gate fails late. When adding `<name>`:

1. **Bundle inventory** — add an entry to `build/native_addons/addon_inventory.bzl` (binary target, `manifest_entries`, `platforms`).
2. **Bazel build graph** — the binary's `BUILD.bazel` must declare every dep/src. Rust: use `all_crate_deps(...)` if it has crate-universe deps (a missing `deps` shows up as `unresolved import` only under Bazel). Go: list new `srcs` (incl. `*_linux.go`/`*_other.go` build-tag files) + `deps`. A green `go test ./...` / `cargo test` does NOT prove the Bazel build — run `bazel build //build/native_addons:<name>_bundle`.
3. **Version-bump gate** — register `<name>` in `scripts/check-native-addon-version-bumps.sh` (`addon_ids`, `manifest_path`, `path_belongs_to_addon`). Any change to the add-on's source/config/unit/bundle inventory requires bumping `addons/<name>/addon.yaml` `version`.
   - **The gate decides "changed" by matching changed PATHS**, and the add-on's `BUILD.bazel` is one of them — so a build-only edit that cannot alter the binary still demands a bump. Keep tunables out of an add-on's `BUILD.bazel` for that reason. There are no RBE task-size hints on any add-on today: `NATIVE_ADDON_EXEC_PROPERTIES` and `//build/rbe:exec_properties.bzl` existed to survive Firecracker's ~2.5Gi default microVM, and were removed with it — `//build/rbe:BUILD` explains why a platform-wide default is worse than BuildBuddy's own per-action measurement. If a link step ever OOMs again, size that one target and keep the value outside the add-on's `BUILD.bazel`. Do not "fix" a false positive by teaching the gate to skip `BUILD.bazel` — that trades it for a false negative, a changed artifact shipping under an unchanged version, which is the whole point of the gate.
   - A few add-ons cross-check a version constant in Bazel (currently only `NETPROBE_VERSION` in `rust/netprobe/BUILD.bazel`, via `bazel_version_constant`); bump those in the same commit.
   - An add-on that consumes a separate crate-universe extension (currently the RDP connector) additionally requires `MODULE.bazel.lock` to record that extension's `Cargo.lock` and `Cargo.toml` hashes — run `bazel --batch mod deps --lockfile_mode=update` twice if the first pass rewrites the lockfile.
   - **A Rust add-on's `Cargo.toml` `[package] version` does NOT have to match, and no vendor snapshot needs refreshing for a bump.** That coupling was deliberately removed; see the note at `check-native-addon-version-bumps.sh:117-131`. It was decoration — these crates are binaries nothing depends on as a library — but mirroring the version edited a manifest, which changed `Cargo.lock`, which invalidated the vendored tree's input index, whose documented fix rewrote 625 crate directories and discarded the Bazel cache for every Rust target, all to restate a version that changed no third-party crate.
4. **Manifest-validation gate** — add `//addons/<name>:addon.yaml` to BOTH the `args` and `data` lists of `validate_addon_manifests_test` in `build/native_addons/BUILD.bazel`. The `inventory_consistency_test` enforces that every add-on in `addon_inventory.bzl` is also in that test; it runs ONLY in the native-addons publish gate (not in a plain `bazel build`), so a missing entry fails the **release publish** late, not your local build.

Verify locally before pushing: `bash scripts/check-native-addon-version-bumps.sh origin/staging <commit-sha>` (with jj, git `HEAD` is the parent — pass the real commit, e.g. `jj log -r @ --no-graph -T commit_id`) AND `bazel test //build/native_addons:build_gates_test` (this is the gate the release publish runs; a plain bundle build does not).

### Adding a new `elixir/serviceradar_core` test file

Every test source selected by
[`ordinary_core_test_sources()`](ci_heavy_gate_contract_test.py) must have a row in
`elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`, or
`ci_heavy_gate_contract_test.py`'s
`test_integration_disposition_inventory_is_exhaustive_and_concrete` fails.
This check runs in **`make test` / BazelCI**, but not in `mix test` or the
Elixir Quality GitHub Action. A new test file can therefore look completely green
through normal local iteration and PR checks, then fail BazelCI alone.
`build/integration_selection_equivalence_test.exs` fails downstream of the
same gap, since the pruned/all-source test selection it compares is derived
from this same inventory.

Add a tab-separated row: `source\tmodule\tcase_kind\tmode\treason\tevidence`.
Two dispositions cover almost everything:

- **Database-free** (plain `ExUnit.Case`, no `:integration`/`:requires_app`
  tag, no `Repo`/data-layer call): set `source` to the new test's path relative
  to `elixir/serviceradar_core/`, `module` = `-`, `case_kind` = `not_selected`,
  `mode` = `load_only`, and `reason` = `not_selected`. For `evidence`, copy the
  standard audit sentence from a neighboring `not_selected` row, as shown
  below. This is the default for most simple unit tests and needs
  **no** change to `build/integration_test_dispositions.bzl`, which only
  tracks `selected` (async/serial) tests.

  Example with all six fields in order, separated by literal tabs (replace
  the example source path with your new test's path):

  ```tsv
  test/example_test.exs	-	not_selected	load_only	not_selected	Static selection audit: this ALL_TEST_SRCS source has zero :integration/:requires_app identities; formatter not run.
  ```

- **DB-backed** (`ServiceRadar.DataCase` or a real data-layer call): needs a
  real `case_kind`/`mode`/`reason` reflecting actual transaction/sandbox
  ownership (`data_case`/`async`/`transaction_owner`, or `serial` with a
  specific reason from `SERIAL_REASONS`) — read a few neighboring rows for an
  analogous test and match their reasoning style; the `evidence` column must
  describe the actual file, not just repeat the reason.

Verify locally before pushing (no Bazel/Docker required):
`python3 -m unittest ci_heavy_gate_contract_test` from the repo root.

## Socket Firewall

Prefer Socket Firewall for supported dependency-fetching commands. Prefix JavaScript/TypeScript package manager calls with `sfw`, especially `npm` commands such as `sfw npm ci`, `sfw npm install`, and `sfw npm run ...` when the command may fetch packages. Also use `sfw` for supported Python and Rust package managers (`pip`, `uv`, and `cargo`) when they may download dependencies. Web-NG uses Bun for asset builds; prefix Bun package-manager invocations with `sfw` in CI and Bazel release tooling as a best-effort firewall even though Socket Firewall Free only officially guarantees npm/yarn/pnpm for JavaScript. Socket Firewall Free does not currently support Go, Bazel, or Hex/Mix, so do not wrap those commands unless Socket adds support.

## Coding Guidelines

- **Go**: run `gofmt` on modified files; keep imports organized; favor existing helper utilities in `pkg/`. Avoid introducing new dependencies without updating `go.mod` and Bazel `MODULE.bazel`/`MODULE.bazel.lock` if required.
- **Rust**: run `cargo fmt` + `cargo clippy` on touched crates (notably `rust/srql`); leverage existing Diesel helpers + CNPG pooling utilities before adding new abstractions.
- **Elixir / Dialyzer**: prefer idiomatic Elixir (`MapSet.new/1`, direct `GRPC.Stub.connect/2`, normal Ash reads). Treat Dialyzer as advisory for false positives (opaque types, incomplete PLT success typing). See **Hard Rules** — never degrade APIs to silence the type checker. Use `mix dialyzer --format dialyzer` when Dialyxir short format crashes on unknown warning kinds.
- **Docs**: place new operational runbooks under `docs/docs/`; keep Markdown ASCII only.
- **OpenSpec**: `openspec validate <change> --strict` reads a requirement's FIRST
  line as its normative statement, not the whole block. A `### Requirement:` that
  opens with narrative -- a "CORRECTED while implementing" note, a rationale
  paragraph -- is reported as containing no SHALL or MUST even when it contains
  several. Lead with the SHALL/MUST sentence and put the narrative below it.

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

Full detail: **`rust/README_RUST.md`**. The rules below are the ones an agent violates by accident.

- **Every dependency version lives in `[workspace.dependencies]` in the root `Cargo.toml`, alphabetically sorted.** A crate under `/rust/` NEVER names a version — it uses `{ workspace = true, features = [...] }`. Cargo and Bazel both read this one list, which is what keeps the two builds from drifting. The only local version is `sha2` in `rust/srql` (documented as BLOCKED at the declaration); `rust/rdp-connector-probe` is deliberately detached.
- **A green `cargo check` does NOT prove the Bazel build.** Cargo.lock is feature-independent and keeps optional deps that are never activated; `cargo vendor` vendors the whole lock, so Bazel compiles crates Cargo prunes. Finish every dependency change with `bazel build //rust/...` — and use `cargo check --workspace --lib --bins --tests`, because plain `cargo check` skips test code while Bazel compiles tests.
- **`cargo check -p <crate>` must pass standalone.** Workspace builds unify features, so a crate missing `features = ["transport"]` still compiles because another crate enabled it. That is an accident, not a dependency.
- **`default-features = false` is only safe when the compiler catches the loss.** A dropped default that is a *runtime* backend compiles clean and fails in production — this exact mistake removed `ureq`'s TLS transport. Before disabling defaults, ask what the defaults *do*. Crates whose defaults every consumer needs (`async-nats`, `toml`, `axum`, `prometheus`, `env_logger`, `ureq`) deliberately keep them.
- **`bazel run //third_party/crate_mirror:sync` is the only supported way to refresh `//third_party/crate_mirror`.** It reads `Cargo.lock`, downloads each registry crate's `.crate` archive, verifies it against the checksum Cargo already recorded, and prunes archives no longer in the lock. `.bazelrc` points `--distdir` at that directory and rules_rs asks for `{crate}-{version}.crate`, which is the only basename Bazel's distdir matches on — so the archives resolve offline. It is a fallback rather than an enforcement: anything missing is downloaded, so a stale mirror degrades instead of breaking. Source patches are `crate.annotation` `patches` entries, applied by rules_rs at fetch time, so they are declared build inputs rather than edits to a tree on disk.
- **OpenSSL for Rust comes from the `@openssl` BCR module, never from a vendored `openssl-src` build and never from the machine.** It is a `cc_library` compiled by the same cc toolchain as everything else, so it cross-compiles by selecting on the target platform. `openssl-sys` is pointed at it in `//MODULE.bazel`, and `pq-src` links what `openssl-sys` resolves — keep that pairing. Two traps, both measured: the RBE executor image exports `OPENSSL_LIB_DIR`/`OPENSSL_INCLUDE_DIR`, which `openssl-sys` reads **before** `OPENSSL_DIR`, so those two must be set explicitly or the build silently links the executor's OpenSSL; and `pq-src` needs `@openssl//:gen_dir` in its own `build_script_data`, because `DEP_OPENSSL_INCLUDE` gives it a path, not an input. Do **not** re-enable `openssl-sys`' `vendored` feature in a Bazel build — `rust/srql`'s `vendored-openssl` feature is off by default and exists only for `cargo test` without a system OpenSSL.
- **One system crate is patched and pinned: `pq-src`** (patch in `//third_party/rust_patches/`, pin `pq-sys = "=0.7.5"` in the root `Cargo.toml`). It builds libpq from source, which is what keeps the build off system libpq paths. The patch is declared as an annotation `patches` entry, so a version bump that invalidates it fails the fetch loudly — **do not paper over that**: the patch is macOS-only, so skipping it leaves Linux CI green and breaks a developer's machine later. Bumping is a deliberate act: re-pin, regenerate the patch, verify on macOS **and** Linux.
- **Adding a dep to a crate whose `BUILD.bazel` names deps explicitly as `@crates//:<name>` labels means adding the label there too** — Bazel will not infer it (`all_crate_deps(...)` does). Always pass `cargo_only = True` to `all_crate_deps`: without it the result also carries first-party workspace members as `//rust/...` labels, which every BUILD file here already lists by hand, and Bazel rejects the duplicate. Per-crate build tweaks are `crate.annotation` tags in `MODULE.bazel`; a crate that no workspace member depends on cannot be added at all (there is no `crate.spec`) — see `//rust/protoc-plugins`.
- **`rust_test(crate = ":x")` does NOT inherit `crate_features`** — repeat them, or the test compiles a different crate than the one that ships. Test fixtures need `data` **and** a runfiles-aware path (`CARGO_MANIFEST_DIR` → `TEST_SRCDIR` → relative); see `flowgger`'s `fixture_path`.
- **Every crate with `#[cfg(test)]` code needs a `rust_test` target.** This is not bookkeeping: flowgger silently carried a 2016 `serde_json`, notify 4.x APIs, and fully broken config parsing because nothing ran its tests.

## Iron Laws

- **LiveView**: no database queries in disconnected mount. Use streams for lists larger than 100 items. Check `connected?/1` before PubSub subscribe.
- **Ecto**: never use `:float` for money. Always pin values with `^` in queries. Use separate queries for `has_many`, `JOIN` for `belongs_to`.
- **Oban**: jobs must be idempotent. Args use string keys. Never store structs in args.
- **Security**: no `String.to_atom/1` with user input. Authorize in every LiveView `handle_event`. Never use `raw/1` with untrusted content.
- **OTP**: no process without a runtime reason. Supervise all long-lived processes.
- **Elixir**: declare `@external_resource` for compile-time files. Wrap third-party library APIs behind project-owned modules. Never use `assign_new` for values refreshed every mount.

## Operational Runbooks

Reference `docs/docs/agents.md` for: faker deployment details, CNPG truncate/reseed steps, materialized view recreation, and stream replay commands. Use those instructions whenever resetting the demo environment or investigating canonical device counts.

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

## Demo Namespace Helm Refresh

- Build and push release artifacts: `make build` then `make push_all`.
- Deploy to demo: `helm upgrade --install serviceradar ./helm/serviceradar -n demo -f helm/serviceradar/values-demo.yaml --set global.imageTag="sha-<git-sha>" --rollback-on-failure`.
  - `values-demo.yaml` carries the `external-dns` annotation for `demo-gw.serviceradar.cloud`; using only `values.yaml` will drop the DNS record.
- `values-demo.yaml` is an overlay on top of `values.yaml`, not a full copy of every chart value. Missing keys usually mean "inherit the default chart value."
- Demo pins ServiceRadar workloads to immutable `sha-...` tags via `global.imageTag`; use `image.digests` only when you need per-service overrides.
- Demo admission is Kyverno-enforced. Images admitted to `demo` must be signed with the release key that matches `docs/cosign.pub`; local `~/.cosign/cosign.key` signatures will not pass cluster policy.
- Local convenience helper: `sr_demo_deploy <sha-...|git-sha>`
  - Defined in `~/.zshrc`
  - Example: `sr_demo_deploy ad617c5f8a067f1e3e93872704754b9f7d006697`
  - If the function is not loaded in the current shell yet, run `source ~/.zshrc`
- Sanity check: `kubectl get pods -n demo` and `helm status serviceradar -n demo`.

### Fast Path: web-ng-only demo refresh

Use this when the diff only touches `elixir/web-ng/**` and you want a faster `demo` rollout without rerunning the full container publish graph.

1. Confirm the scope is narrow:
   - `git diff --name-only <currently-deployed-sha>..HEAD`
   - If only `elixir/web-ng/**` changed, rebuild just `serviceradar-web-ng` and copy the other images forward to the new immutable tag.
2. Copy unchanged images from the current demo tag to the new tag:
   - `/tmp/gobin/crane cp registry.carverauto.dev/serviceradar/<image>:sha-<old> registry.carverauto.dev/serviceradar/<image>:sha-<new>`
   - Repeat for `serviceradar-agent`, `serviceradar-agent-gateway`, `serviceradar-core-elx`, `serviceradar-datasvc`, `serviceradar-faker`, `serviceradar-flow-collector`, `serviceradar-log-collector`, `serviceradar-rperf-client`, `serviceradar-tools`, `serviceradar-trapd`, and `arancini`.
3. Rebuild the production `web-ng` release locally:
   - `cd elixir/web-ng`
   - `MIX_ENV=prod HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 mix deps.compile`
   - `MIX_ENV=prod HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 mix compile`
   - `MIX_ENV=prod HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 mix assets.deploy`
   - `MIX_ENV=prod HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 mix release --path /tmp/serviceradar_web_ng_release_<shortsha>`
4. Package and push the new `web-ng` image directly with `crane`:
   - `tar --owner=10001 --group=10001 --transform='s,^,app/,' -cf /tmp/serviceradar_web_ng_layer_<shortsha>.tar -C /tmp/serviceradar_web_ng_release_<shortsha> .`
   - `/tmp/gobin/crane append --platform linux/amd64 -b index.docker.io/hexpm/elixir:1.19.4-erlang-28.3-debian-bookworm-20251208-slim -f /tmp/serviceradar_web_ng_layer_<shortsha>.tar -t registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-<new>`
   - `/tmp/gobin/crane mutate --platform linux/amd64 --tag registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-<new> --entrypoint /app/bin/serviceradar_web_ng --cmd start --env HOME=/app --env PATH=/app/bin:/usr/local/bin:/usr/bin:/bin --env PHX_SERVER=true --env MIX_ENV=prod --exposed-ports 4000/tcp --user 10001:10001 --workdir /app registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-<new>`
5. Sign the new `web-ng` tag with the release signer, not a local key:
   - Port-forward OpenBao if needed: `kubectl port-forward -n vault svc/openbao 18200:8200`
   - Exchange the Forgejo runner service account token for a Vault token and set `VAULT_ADDR=http://127.0.0.1:18200`
   - `export COSIGN_KEY_REF=hashivault://cosign-release`
   - `export COSIGN_YES=true COSIGN_DOCKER_MEDIA_TYPES=1 COSIGN_REFERRERS_MODE=legacy COSIGN_TLOG_UPLOAD=true`
   - `cosign sign --key "$COSIGN_KEY_REF" registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-<new>`
6. Patch the Argo app override instead of editing chart values for one-off demo tests:
   - `kubectl patch application -n argocd serviceradar-demo-prod --type merge -p '{"spec":{"source":{"helm":{"parameters":[{"name":"global.imageTag","value":"sha-<new>"}]}}}}'`
7. Watch the rollout to completion:
   - `kubectl get application -n argocd serviceradar-demo-prod -o jsonpath='{.status.sync.status}{"|"}{.status.health.status}{"|"}{.status.operationState.phase}{"\n"}'`
   - `kubectl get deploy -n demo serviceradar-web-ng serviceradar-core serviceradar-agent serviceradar-tools -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'`
   - Expect temporary `OutOfSync|Healthy|Running` or `Synced|Progressing|Running` while hook jobs such as runtime cert generation or NATS credential generation complete.
   - Finish only when Argo reports `Synced|Healthy|Succeeded` and the key `demo` pods are `Running` on `sha-<new>`.

## Docker Compose Refresh

- Build and publish release artifacts from the current commit: `make build` then `make push_all`.
- Capture the tag for compose: `git rev-parse HEAD` and use `APP_TAG=sha-<sha>`.
- Pull fresh images: `APP_TAG=sha-<sha> docker compose pull`.
- Restart the stack: `APP_TAG=sha-<sha> docker compose up -d --force-recreate`.
- Verify: `docker compose ps` (one-shot jobs like cert-generator/config-updater exit once finished).

## Local Development with Docker CNPG

Use this quick playbook when running `mix phx.server` locally and connecting to the CNPG instance in Docker on the same machine. This is the fastest iteration loop for testing changes.

### 1. Ensure Docker Compose is Running

Make sure CNPG is accessible on port 5455:

```bash
cd docker/compose
APP_TAG=sha-<commit> docker compose up -d cnpg
```

### 2. Copy Client Certs to a Local Directory (one-time setup)

```bash
mkdir -p .local-dev-certs
sudo cp /var/lib/docker/volumes/serviceradar_cert-data/_data/{root.pem,workstation.pem,workstation-key.pem} .local-dev-certs/
sudo chown -R $USER:$USER .local-dev-certs
```

Note: `.local-dev-certs/` is already in `.gitignore`.

### 3. Run Phoenix Locally

```bash
cd elixir/web-ng
CNPG_HOST=localhost CNPG_PORT=5455 CNPG_SSL_MODE=verify-full \
  CNPG_CERT_DIR=/home/<user>/serviceradar/.local-dev-certs \
  CNPG_TLS_SERVER_NAME=cnpg \
  mix phx.server
```

Or for local testing without network:

```bash
CNPG_HOST=localhost CNPG_PORT=5455 CNPG_SSL_MODE=verify-full \
  CNPG_CERT_DIR=$PWD/../.local-dev-certs CNPG_TLS_SERVER_NAME=cnpg \
  mix phx.server
```

### 4. Access the App

- Web UI: http://localhost:4000
- Dev Mailbox: http://localhost:4000/dev/mailbox (for testing auth emails)
- Live Dashboard: http://localhost:4000/dev/dashboard

### Troubleshooting

- **Port 4000 already in use**: Kill any stale beam processes with `pkill -f beam.smp`
- **binary_to_existing_atom error**: Ensure you've run `mix compile --force` after updates

## Web-NG Dashboard Visual Testing Loop

Use this when iterating on screenshot-driven dashboard or shell design work in `elixir/web-ng/`.

1. Keep the reference image in a local ignored path such as `tmp/dashboard-reference.png`. Do not commit screenshot references unless explicitly requested.
2. Build static assets after JS/CSS changes:

```bash
cd elixir/web-ng/assets
sfw npm run build:js
sfw npm run build:css
```

3. Start Phoenix locally with noisy background services disabled for visual testing when you need to exercise the real LiveView route:

```bash
cd elixir/web-ng
DATASVC_ENABLED=false SERVICE_HEARTBEAT_ENABLED=false SERVICERADAR_WEB_NG_OBAN_ENABLED=false \
  SERVICERADAR_GOD_VIEW_RUNTIME_GRAPH_AUTO_REFRESH=false \
  CNPG_HOST=localhost CNPG_PORT=5455 CNPG_USERNAME=serviceradar CNPG_PASSWORD=serviceradar \
  CNPG_DATABASE=serviceradar_web_ng_dev CNPG_SSL_MODE=disable \
  PHX_HOST=localhost SERVICERADAR_DEV_ROUTES=true mix phx.server
```

When pointing this loop at the Kubernetes `demo` CNPG instance, use the `$demo-cnpg-local-web-ng` skill instead of hand-rolled port-forwards:

```bash
.agents/skills/demo-cnpg-local-web-ng/scripts/start-local-web-ng.sh
```

The skill/script reads `demo/serviceradar-db-credentials`, tries the GitOps-managed `demo/cnpg-rw-internal-lb` VIP (`192.168.6.82:5432`), then falls back to the current CNPG primary node's NodePort paths such as `10.0.2.11:32040` and `10.0.2.11:30455`. If the `192.168.6.82` VIP fails but NodePort works, treat it as a routing/L2 issue outside web-ng/CNPG. Keep the permanent Kubernetes objects in GitOps (`gitops/k8s/demo-cnpg-internal-access/`), not as one-off live changes.

If the local CNPG requires TLS, use the standard cert-backed command from the Local Development with Docker CNPG section instead. A repeated `Unknown CA` error means the cert bundle does not match the CNPG server; refresh the local certs before relying on the LiveView route. If Phoenix or CNPG is not needed for the current visual pass, create a temporary ignored harness under `tmp/` that loads `elixir/web-ng/priv/static/assets/css/app.css` and mirrors the rendered dashboard HTML.

4. Capture browser screenshots with Playwright or Chromium against `http://localhost:4000/dashboard` after logging in. Use desktop and mobile viewports and compare against the reference:

```bash
npx playwright install chromium
npx playwright screenshot --viewport-size=1680,945 http://localhost:4000/dashboard tmp/dashboard-desktop.png
npx playwright screenshot --viewport-size=390,844 http://localhost:4000/dashboard tmp/dashboard-mobile.png
```

If using the ignored Playwright harness under `tmp/playwright-harness/`, run the repo-root spec with `NODE_PATH` so `@playwright/test` resolves from that harness:

```bash
NODE_PATH=$PWD/tmp/playwright-harness/node_modules \
  DASHBOARD_PREVIEW_EMAIL=root@localhost \
  DASHBOARD_PREVIEW_PASSWORD_FILE=tmp/demo-cnpg/dashboard-password \
  tmp/playwright-harness/node_modules/.bin/playwright test tmp/live-dashboard.spec.js --reporter=line --timeout=120000
```

For a temporary local harness, capture the file URL instead:

```bash
npx playwright screenshot --viewport-size=1680,945 file://$PWD/tmp/dashboard-visual-harness.html tmp/dashboard-desktop.png
```

5. For canvas-heavy dashboard work, verify the screenshot is not blank and that the deck.gl canvas is present. A quick smoke check is to inspect `#ops-traffic-map` in the browser and confirm the canvas dimensions are non-zero.

## Web-NG Remote Dev (CNPG)

Use this playbook to run `elixir/web-ng/` on a workstation while connecting to the existing CNPG instance running on the docker host (example: `192.168.2.134`).

### 1. Publish CNPG on the docker host

- By default, CNPG is bound to loopback only. To allow LAN access, set these in the docker host `.env` (or export them before running compose):
  - `CNPG_PUBLIC_BIND=0.0.0.0` (or a specific LAN interface IP)
  - `CNPG_PUBLIC_PORT=5455`

### 2. Ensure CNPG TLS cert supports IP-based clients (verify-full)

- If clients will connect by IP with `CNPG_SSL_MODE=verify-full`, add the host IP to the CNPG server cert SAN:
  - `CNPG_CERT_EXTRA_IPS=192.168.2.134`
  - Regenerate certs: `CNPG_CERT_EXTRA_IPS=192.168.2.134 docker compose up cert-generator`
  - Restart CNPG (and ensure bind env vars are applied): `CNPG_PUBLIC_BIND=0.0.0.0 CNPG_PUBLIC_PORT=5455 docker compose up -d --force-recreate cnpg`

### 3. Copy workstation client certs (keep out of git)

- Determine the cert volume name: `docker volume ls | rg 'cert-data'`
- Copy out these files from the volume to a private directory on your workstation:
  - `root.pem`
  - `workstation.pem`
  - `workstation-key.pem`

### 4. Run Phoenix from your workstation

```bash
cd elixir/web-ng
export CNPG_HOST=192.168.2.134
export CNPG_PORT=5455
export CNPG_DATABASE=serviceradar
export CNPG_USERNAME=serviceradar
export CNPG_PASSWORD=serviceradar
export CNPG_SSL_MODE=verify-full
export CNPG_CERT_DIR=/path/to/private/serviceradar-certs
mix phx.server
```

## Local mTLS ERTS Cluster (web-ng + agent-gateway)

Use this when validating TLS distribution locally without Docker. This keeps `web-ng` and `serviceradar_agent_gateway` joined over mTLS ERTS.

### 1. Generate local mTLS certs for distribution

```bash
mkdir -p tmp/serviceradar-certs tmp/ssl_dist tmp/logs
sudo CERT_DIR="$PWD/tmp/serviceradar-certs" bash docker/compose/generate-certs.sh
sudo chown -R "$USER:$USER" tmp/serviceradar-certs
```

### 2. Create ssl_dist config files that point at local cert paths

```bash
cp docker/compose/ssl_dist.web.conf tmp/ssl_dist/web.conf
cp docker/compose/ssl_dist.gateway.conf tmp/ssl_dist/gateway.conf
sed -i "s#/etc/serviceradar/certs#$PWD/tmp/serviceradar-certs#g" tmp/ssl_dist/*.conf
```

### 3. Copy Docker CNPG TLS certs for web-ng (if using local docker CNPG)

```bash
mkdir -p tmp/serviceradar-docker-certs
sudo cp /var/lib/docker/volumes/serviceradar_cert-data/_data/{root.pem,workstation.pem,workstation-key.pem} tmp/serviceradar-docker-certs/
sudo chown -R "$USER:$USER" tmp/serviceradar-docker-certs
```

### 4. Start agent gateway with TLS distribution (use 127.0.0.1 names)

```bash
ERL_FLAGS="-name serviceradar_agent_gateway@127.0.0.1 -setcookie serviceradar_dev_cookie -proto_dist inet_tls -ssl_dist_optfile $PWD/tmp/ssl_dist/gateway.conf" \
CLUSTER_ENABLED=true CLUSTER_STRATEGY=epmd \
CLUSTER_HOSTS=serviceradar_web_ng@127.0.0.1 \
ENABLE_TLS_DIST=true SSL_DIST_OPTFILE=$PWD/tmp/ssl_dist/gateway.conf \
SPIFFE_CERT_DIR=$PWD/tmp/serviceradar-certs \
GATEWAY_PARTITION_ID=local GATEWAY_ID=gateway-local-1 GATEWAY_DOMAIN=local GATEWAY_CAPABILITIES=icmp,tcp \
nohup mix run --no-halt > $PWD/tmp/logs/gateway-local.log 2>&1 &
```

### 5. Start web-ng with TLS distribution + CNPG

```bash
ERL_FLAGS="-name serviceradar_web_ng@127.0.0.1 -setcookie serviceradar_dev_cookie -proto_dist inet_tls -ssl_dist_optfile $PWD/tmp/ssl_dist/web.conf" \
CLUSTER_ENABLED=true CLUSTER_STRATEGY=epmd \
CLUSTER_HOSTS=serviceradar_agent_gateway@127.0.0.1 \
CLUSTER_TLS_ENABLED=true SSL_DIST_OPTFILE=$PWD/tmp/ssl_dist/web.conf \
CNPG_HOST=localhost CNPG_PORT=5455 CNPG_USERNAME=serviceradar CNPG_PASSWORD=serviceradar \
CNPG_DATABASE=serviceradar_web_ng_dev CNPG_SSL_MODE=verify-ca \
CNPG_CA_FILE=$PWD/tmp/serviceradar-docker-certs/root.pem \
CNPG_CERT_FILE=$PWD/tmp/serviceradar-docker-certs/workstation.pem \
CNPG_KEY_FILE=$PWD/tmp/serviceradar-docker-certs/workstation-key.pem \
PHX_HOST=localhost SERVICERADAR_DEV_ROUTES=true SERVICERADAR_LOCAL_MAILER=true \
nohup mix phx.server > $PWD/tmp/logs/web-ng.log 2>&1 &
```

### 6. Verify cluster membership via observer node

```bash
cat > tmp/ssl_dist/observer.conf <<EOF
[{server, [
  {certfile, "$PWD/tmp/serviceradar-certs/workstation.pem"},
  {keyfile, "$PWD/tmp/serviceradar-certs/workstation-key.pem"},
  {cacertfile, "$PWD/tmp/serviceradar-certs/root.pem"},
  {verify, verify_peer},
  {fail_if_no_peer_cert, true},
  {secure_renegotiate, true},
  {depth, 2}
]},
{client, [
  {certfile, "$PWD/tmp/serviceradar-certs/workstation.pem"},
  {keyfile, "$PWD/tmp/serviceradar-certs/workstation-key.pem"},
  {cacertfile, "$PWD/tmp/serviceradar-certs/root.pem"},
  {verify, verify_peer},
  {secure_renegotiate, true},
  {depth, 2}
]}].
EOF

ERL_FLAGS="-name observer@127.0.0.1 -setcookie serviceradar_dev_cookie -proto_dist inet_tls -ssl_dist_optfile $PWD/tmp/ssl_dist/observer.conf" \
elixir -e 'IO.inspect(:rpc.call(:\"serviceradar_agent_gateway@127.0.0.1\", Node, :list, []))'
```

Note: using `@127.0.0.1` avoids the ERTS error `System running to use fully qualified hostnames` that you get with `@localhost`.

## Docker Compose mTLS ERTS (IEx/remote)

When using the Docker Compose stack, TLS distribution is enabled via `/etc/serviceradar/ssl_dist.conf` and certs live under `/etc/serviceradar/certs`.
Use the release `remote` command from inside the containers so node names resolve on the Docker network:

```bash
docker exec -it serviceradar-web-ng-mtls /app/bin/serviceradar_web_ng remote
docker exec -it serviceradar-core-elx-mtls /app/bin/serviceradar_core_elx remote
docker exec -it serviceradar-agent-gateway-mtls /app/bin/serviceradar_agent_gateway remote
```

If you need a host-side IEx shell, run a one-off container on the same Docker network with the cert volume mounted so the TLS cert paths resolve:

```bash
CERT_VOLUME=$(docker volume ls --format '{{.Name}}' | rg 'cert-data' | head -n1)
docker run --rm -it --network serviceradar-net \
  -v "${CERT_VOLUME}:/etc/serviceradar/certs" \
  registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-<sha> \
  /app/bin/serviceradar_web_ng remote
```

If distribution fails with `bad_cert` or `hostname_check_failed` for `agent-gateway`, rerun `docker compose run --rm cert-generator` to refresh certs after updating `docker/compose/generate-certs.sh`.
If you see `hostname_check_failed` for `core-elx`, ensure the core certificate SAN list includes `DNS:core-elx` (and `core`, `serviceradar-core`) in `docker/compose/generate-certs.sh`, then rerun the cert generator.

## Edge Onboarding Testing with Docker mTLS Stack

Use this playbook to test edge onboarding functionality (e.g., sysmon checker mTLS bootstrap) against the Docker Compose mTLS stack.

### 1. Get Admin Credentials

The config-updater container generates admin credentials at startup:

```bash
cd docker/compose
docker compose logs config-updater 2>&1 | grep -E "(Username|Password)"
```

Look for output like:
```
Username: admin
Password: HaM5aHNMqLFA9gtq
```

### 2. Obtain a JWT Token

Authenticate against the Core API (port 8090) using the credentials:

```bash
curl -s -X POST http://localhost:8090/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<PASSWORD>"}' | jq -r '.access_token' > /tmp/jwt_token.txt
```

### 3. Find Available Gateways and Agents

```bash
# List gateways
curl -s "http://localhost:8090/api/gateways" \
  -H "Authorization: Bearer $(cat /tmp/jwt_token.txt)" | jq '.[].gateway_id'

# List agents
curl -s "http://localhost:8090/api/admin/agents" \
  -H "Authorization: Bearer $(cat /tmp/jwt_token.txt)" | jq '.[].agent_id'
```

Typical output: `docker-gateway` and `docker-agent`.

### 4. Create an Edge Onboarding Package

Create a checker package for the sysmon checker:

```bash
curl -s -X POST "http://localhost:8090/api/admin/edge-packages" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(cat /tmp/jwt_token.txt)" \
  -d '{
    "label": "Sysmon Test",
    "component_type": "checker",
    "component_id": "sysmon-test-01",
    "parent_id": "docker-agent",
    "parent_type": "agent",
    "gateway_id": "docker-gateway",
    "checker_kind": "sysmon",
    "security_mode": "mtls",
    "checker_config_json": "{\"listen_addr\":\"0.0.0.0:50083\",\"poll_interval\":30,\"filesystems\":[{\"name\":\"/\",\"type\":\"ext4\",\"monitor\":true}]}"
  }' | tee /tmp/package_response.json
```

Extract the package ID and download token:
```bash
jq -r '.package.package_id' /tmp/package_response.json
jq -r '.download_token' /tmp/package_response.json
```

### 5. Generate an Onboarding Token

Create the `edgepkg-v1:` token format (fields: `pkg`, `dl`, `api`):

```bash
PACKAGE_ID=$(jq -r '.package.package_id' /tmp/package_response.json)
DOWNLOAD_TOKEN=$(jq -r '.download_token' /tmp/package_response.json)
CORE_URL="http://localhost:8090"
TOKEN_PAYLOAD="{\"pkg\":\"$PACKAGE_ID\",\"dl\":\"$DOWNLOAD_TOKEN\",\"api\":\"$CORE_URL\"}"
echo -n "$TOKEN_PAYLOAD" | base64 -w0 | tr '+/' '-_' | tr -d '='
```

Prepend `edgepkg-v1:` to the base64 output for the final token.

### 6. Test the Sysmon Checker with mTLS Bootstrap

Ensure the certificate directory exists with proper permissions:
```bash
sudo mkdir -p /var/lib/serviceradar/checker/{certs,config}
sudo chown -R $USER:$USER /var/lib/serviceradar
```

Run the checker with the token:
```bash
export ONBOARDING_TOKEN="edgepkg-v1:<base64-token>"
./target/release/serviceradar-sysmon-checker \
    --mtls \
    --cert-dir /var/lib/serviceradar/checker/certs \
    --host http://localhost:8090
```

Successful output shows:
- "mTLS bootstrap successful"
- "Generated config at: /var/lib/serviceradar/checker/config/checker.json"
- "Certificates installed to: ..."
- "Server will listen on 0.0.0.0:50083"

### 7. Verify Generated Files

```bash
# Check certificates (key should be 0600)
ls -la /var/lib/serviceradar/checker/certs/

# View generated config
cat /var/lib/serviceradar/checker/config/checker.json | jq '.'
```

### 8. Test Restart Resilience

Restart the checker using the persisted config:
```bash
./target/release/serviceradar-sysmon-checker \
    --config /var/lib/serviceradar/checker/config/checker.json
```

### Notes

- Each package can only be downloaded once (status changes to "delivered").
- Create a new package for each test run.
- The Core API is on port 8090 (direct); browser access goes through the edge proxy on 80/443.
- Edge packages expire based on `download_token_ttl_seconds` (default: 10 minutes).

## Release Playbook

1. Prep metadata:
   - Update `VERSION` with the new semver (example: `1.0.54-pre1`).
   - Add a matching entry at the top of `CHANGELOG` that summarizes the release highlights.
   - Run `scripts/cut-release.sh --version <version> --dry-run` to confirm the changelog entry is detected before committing.
2. Tag the release:
   - Execute `scripts/cut-release.sh --version <version>` to stage `VERSION`/`CHANGELOG`, create the release commit, and author the annotated tag (append `--push` when you are ready to publish the refs).
3. Build and push Bazel release artifacts:
   - Authenticate to Harbor if needed: `./scripts/docker-login.sh`.
   - Run `bazel build -c opt --config=ci $(bazel query 'kind(oci_image, //docker/images:*)')` to ensure every container bakes successfully before publishing.
   - Run `make push_all_release`. This publishes container images plus first-party Wasm plugin OCI artifacts, signs both with cosign, and verifies the published metadata/signatures locally.
   - If a single image needs republishing on Linux/CI, use `bazel run -c opt --config=ci --stamp //docker/images:<target>_push` (for example `//docker/images:web_ng_image_amd64_push`). On macOS use `make push_all`; direct `cache_only` image targets preserve the Darwin platform and cannot produce a valid Linux image.
   - If only Wasm plugins need republishing, run `make push_wasm_plugins`.
   - Capture the new image identifiers you care about (for example `git rev-parse HEAD` for the commit tag or the full digest printed during the push). You'll use these when refreshing Kubernetes.
4. Roll the demo namespace:
   - Run `helm upgrade --install serviceradar ./helm/serviceradar -n demo -f helm/serviceradar/values-demo.yaml --set global.imageTag="sha-<git-sha>" --rollback-on-failure` to roll demo to the newly published immutable tag.
   - Local shortcut: `sr_demo_deploy <sha-...|git-sha>` if the helper is installed in `~/.zshrc`.
   - Watch for readiness: `kubectl get pods -n demo` until all pods are `1/1` and `Running`.
5. Close out: verify the demo web UI reports the new version, file follow-up docs, and proceed with Forgejo release packaging if required.

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

## CNPG Database Access (Kubernetes demo-staging)

Use this section when you need to directly access the CNPG PostgreSQL database in the demo-staging Kubernetes namespace for debugging or data inspection.

### 1. Expose CNPG Service Externally

Patch the CNPG service to use NodePort for external access:

```bash
kubectl patch svc cnpg-staging-rw -n demo-staging -p '{"spec":{"type":"NodePort","ports":[{"port":5432,"nodePort":30432}]}}'
```

Or create a dedicated NodePort service:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: cnpg-staging-external
  namespace: demo-staging
spec:
  type: NodePort
  selector:
    cnpg.io/cluster: cnpg-staging
    cnpg.io/instanceRole: primary
  ports:
    - port: 5432
      targetPort: 5432
      nodePort: 30432
EOF
```

### 2. Get Database Credentials

```bash
# Get the serviceradar user password
kubectl get secret serviceradar-db-credentials -n demo-staging -o jsonpath='{.data.password}' | base64 -d

# Or get the postgres superuser password
kubectl get secret cnpg-staging-superuser -n demo-staging -o jsonpath='{.data.password}' | base64 -d
```

### 3. Connect via psql

```bash
# Using serviceradar user (has search_path=platform, ag_catalog)
PGPASSWORD=$(kubectl get secret serviceradar-db-credentials -n demo-staging -o jsonpath='{.data.password}' | base64 -d) \
  psql -h <node-ip> -p 30432 -U serviceradar -d serviceradar

# Using postgres superuser
PGPASSWORD=$(kubectl get secret cnpg-staging-superuser -n demo-staging -o jsonpath='{.data.password}' | base64 -d) \
  psql -h <node-ip> -p 30432 -U postgres -d serviceradar
```

Replace `<node-ip>` with your Kubernetes node IP (e.g., `localhost` if running locally).

### 4. Alternative: kubectl exec into CNPG Pod

For quick one-off queries without exposing the service:

```bash
kubectl exec -it cnpg-staging-1 -n demo-staging -- psql -U serviceradar -d serviceradar
```

### 5. Common Queries

```sql
-- Check service_status table (uses platform schema via search_path)
SELECT COUNT(*) FROM service_status;

-- Query specific service history
SELECT timestamp, service_name, available, message
FROM service_status
WHERE service_name = 'Hello Wasm'
ORDER BY timestamp DESC
LIMIT 20;

-- Check schema search_path
SHOW search_path;
```

### Notes

- The `serviceradar` user has `search_path=platform, ag_catalog` set, so tables in the `platform` schema are accessed without prefix.
- For production debugging, prefer `kubectl exec` over exposing the service externally.
- Remember to clean up NodePort services when done: `kubectl delete svc cnpg-staging-external -n demo-staging`

## SRQL Fixture Integration Tests

Use the `srql-fixtures-db-tests` skill when `elixir/serviceradar_core` integration tests need
the shared CNPG/AGE fixture. There is deliberately no orchestration script: invoke the guarded
Bazel lifecycle in order as the caller:

```text
sweep -> provision base -> migrate run if pending -> provision lanes -> test -> teardown
```

**You cannot run `//elixir/serviceradar_core:migrate_template` from a branch, and should not
try.** `sr_core_template` is shared by every run on the fixture and only ratchets forward, so
migrating it from a branch checkout writes that branch's unmerged migrations into the schema
every other branch clones -- and every branch whose checkout lacks them is then refused. That is
not hypothetical: one branch left seven behind and every other pull request went red on a step
unrelated to its own diff. The template is advanced by the trunk lifecycle alone
(`LargeIngestionGate`, push to `staging`).

The three targets that write it -- `//elixir/serviceradar_core:migrate_template`,
`//rust/integration-db:prepare_template` and `//rust/integration-db:reset_template` -- now
**refuse** without `--//build:template_authority=true`, which is the caller declaring "this
checkout is trunk". Only `LargeIngestionGate` passes it, and
`//:ci_heavy_gate_contract_test` pins that. Do not pass it to get past a refusal: the flag is a
statement about the checkout, not a way to unblock a step, and a branch that sets it reproduces
the original outage exactly. It fails closed -- an absent or empty marker is a refusal -- so
adding the flag to a target that does not declare `//build:template_authority_file` changes
nothing.

A branch's own migrations go to its **run base**: `//rust/integration-db:provision_base` seeds
`sr_core_test_<run>` from the template, `//elixir/serviceradar_core:migrate_run` brings that one
database up to the checkout, and the lane databases are cloned from it. If `provision_base`
reports the template AHEAD of the checkout it does not fail -- it builds the base from nothing,
says so, and leaves the shared template alone. `bazel run //rust/integration-db:reset_template`
is the deliberate recovery when the template has diverged from trunk; the trunk lifecycle runs it
automatically in that case.

For one shard, pair `//rust/integration-db:provision_db_sN` with
`//elixir/serviceradar_core:integration_tests_sN`. CI uses the unsuffixed provision target and
the eight-shard suite. Every test/lifecycle invocation needs
`--//build:enable_integration_tests --strategy=TestRunner=local --test_tag_filters=`; prepare is
`bazel run` and needs `--build_tag_filters=`. Always pass `--nocache_test_results` to the mutable
database tests, and always invoke `teardown_db` after a red shard. Bazel has no cross-invocation
finalizer; the stale sweep is the backstop for a killed host.

Keep fixture base URLs in `SRQL_TEST_DATABASE_URL` and `SRQL_TEST_ADMIN_URL`, mint ONE run id
for the whole sequence and pass it to every invocation as `--//build:run_id=<id>` (8-32 chars of
`[a-z0-9]`; it has no default, because a constant fallback let two runs share one database), and
leave
`SERVICERADAR_TEST_DATABASE_URL` unset so each shard derives its disposable database. When using
a NodePort, export both `PGSSLSERVERNAME` and `SRQL_TEST_DATABASE_SERVER_NAME` with the CNPG
certificate's DNS name so the Rust and Elixir clients verify the same certificate.

**BazelCI runs the PR head's `buildbuddy.yaml` against the MERGED tree.** It merges
`origin/staging` into the branch before building, but the workflow steps come from the
branch's own `buildbuddy.yaml`. So a branch that predates a lifecycle change runs the OLD
step sequence against NEW `//rust/integration-db` code, and the symptom names neither: a
`provision_db` failing with `sr_core_test_<run> does not exist; run
//rust/integration-db:provision_base first` means the branch's `buildbuddy.yaml` has no
`provision_base` step, not that the fixture is broken. Diff `buildbuddy.yaml` against
`origin/staging` before reading further; the fix is a rebase, not a code change.

With a mode-0600 ignored `.bazelrc.remote` containing the BuildBuddy credential, add
`--config=cache_only`: compilation artifacts use the public authenticated cache while
`TestRunner` remains native. Do not use `--config=ci` for a local database test; it selects the
Linux RBE platform. Never copy or print fixture or BuildBuddy credentials while diagnosing this
flow. The skill contains the exact command sequence and cleanup check.
