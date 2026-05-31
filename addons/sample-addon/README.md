# Sample native add-on

Reference native add-on for the agent feature-sets framework (issue #3425). It
exists to prove the `go-plugin` add-on contract end to end — manifest →
signed bundle → control-plane catalog → agent-side supervision — and to serve as
the copy-me starting point for new first-party add-ons.

It is intentionally trivial: it accepts a single `message` config field and
reports healthy. The behavior is not the point; the wiring is.

## `addons/<id>/` layout convention

A native add-on's **manifest package** lives under `addons/<id>/`:

| File | Purpose |
| --- | --- |
| `addon.yaml` | The add-on manifest (identity, delivery/supervision model, capabilities, requirements, exec, config-schema pointer). Mirrors `plugin.yaml` for WASM plugins. |
| `config.schema.json` | JSON Schema (draft 2020-12) for operator-supplied config. The control plane validates `AddonAssignment.params` against this before persisting. |
| `BUILD.bazel` | Exposes the manifest files (`exports_files` + a `filegroup`) so the signed-bundle build can pull them in. |
| `README.md` | This file — what the add-on is and how it maps onto the framework. |

The add-on's **implementation sources** live next to the rest of the codebase,
not in this directory:

- Go add-ons: `go/cmd/serviceradar-<id>-addon/` (this one: `go/cmd/serviceradar-sample-addon/`).
- Rust add-ons: built against `rust/addon-sdk` (reference: the `rust-sample` add-on, sources in `rust/addon-sdk/src/bin/rust_sample_addon.rs`, manifest in `addons/rust-sample-addon/`).

Keeping the manifest package separate from the source keeps the manifest a small,
reviewable surface and lets the build assemble the per-arch signed bundle from the
compiled binary plus these manifest files.

## Manifest (`addon.yaml`) at a glance

```yaml
id: sample                    # stable add-on id (matches AddonPackage.addon_id)
version: 0.1.0
kind: native
delivery: pushed-artifact     # compiled-in | pushed-artifact | os-package
supervision: agent-sidecar    # config-toggle | agent-sidecar | systemd-service | systemd-timer | ephemeral-helper
language: go                  # go | rust
capabilities: [sample]        # capability ids this add-on advertises
requires:
  base_agent: ">=1.2.0"
  platforms: [linux]
  run_as: serviceradar
plugin:
  protocol: grpc              # go-plugin transport
  app_protocol_version: 1
exec:
  binary: serviceradar-sample-addon
  install_path: /usr/local/lib/serviceradar/bin
config_schema: config.schema.json
```

`delivery` + `supervision` are the two axes the agent dispatches on. This sample is
`pushed-artifact` / `agent-sidecar`: a signed per-arch tarball delivered over the
runtime-push rail and supervised by the agent as a `go-plugin` subprocess.

`artifacts[]` (per-arch `object_key` / `sha256` / `signature_ref`) are **not** in
this source manifest — they are populated by the signed-bundle build
(see the `native-addon-builds` capability) and recorded on the `AddonPackage`.

## How it flows through the framework

1. **Build** — `build/native_addons/addon_inventory.bzl` lists this add-on; the
   Bazel rules cross-compile `serviceradar-sample-addon` per `(os, arch)` and
   assemble a deterministic, signed bundle with a `sha256` + `metadata.json`.
2. **Catalog** — an `AddonPackage` (Ash, `staged → approved → revoked`) records the
   manifest, per-arch artifacts, and `config_schema`. An operator approves it,
   optionally narrowing `approved_capabilities`.
3. **Assign** — an `AddonAssignment` targets an agent (uid or cohort) with
   `enabled` + `params`; params are validated against `config.schema.json` before
   persisting.
4. **Deliver** — `AgentConfigGenerator` compiles enabled+approved assignments into
   the typed `AddonAssignmentConfig` section of `AgentConfigResponse`, includes them
   in the `config_version` hash, and the dependency catalog pushes the new config to
   affected agents.
5. **Supervise** — the agent's add-on manager (`go/pkg/agent/addon`) launches the
   `agent-sidecar` as a `go-plugin` client over a Unix-domain socket with AutoMTLS,
   runs health checks with restart backoff + a circuit breaker, and re-launches on a
   binary/args change.
6. **Report** — per-add-on `installed/active/unhealthy` status is reported upward in
   the agent capability status and surfaced per agent.

## Authoring a new add-on

See the operator/author overview and the **author checklist** in
[`docs/docs/native-addons.md`](../../docs/docs/native-addons.md). The short version:
copy this directory to `addons/<your-id>/`, write your manifest + schema, implement
the add-on service against the Go SDK (`go/pkg/addon`) using the gRPC contract in
`proto/agent/addon/v1/`, and add an inventory entry so the release build picks it up.
