# Tasks: Native add-on build, signing & import pipeline

> Implements the publish-and-ingest half of `add-agent-feature-sets`. Task numbers in
> parentheses map back to that change's tasks.md.

## 1. Manifest validation
- [x] 1.1 Author the `addon.yaml` manifest JSON-Schema (id, name, version, kind,
  delivery, supervision, capabilities, requires, artifacts, exec, state_dirs,
  config_schema) and a validator. (3425 §1.1)
  - Schema: `addons/native-addon-manifest.schema.json` (JSON-Schema 2020-12).
  - Validator: `go/tools/addon-manifest-validator` (Go command + `internal/manifestschema`
    library, schema embedded, valid + invalid fixtures and unit tests).
- [x] 1.2 Wire the validator as a build/CI gate that fails before bundling on an
  invalid `addon.yaml` or an unsupported `config.schema.json` subset.
  - CI/Make gate: `make validate_addon_manifests` (and `make addon_build_gates`),
    fails closed (exit 1) on an invalid manifest.
  - In-bundle gate: `build/native_addons/assemble_addon_bundle.py` now validates the
    manifest (required fields + kind/delivery/supervision enums) and refuses to emit
    a bundle on a violation, so raw `bazel build` also fails closed before bundling.
  - NOTE: the `config.schema.json` *subset* validation (rejecting an unsupported JSON
    Schema subset for the config file) is NOT implemented here; only the manifest's
    `config_schema` *reference* is required/validated.

## 2. Signing & discovery (capability: native-addon-builds)
- [x] 2.1 Reuse `scripts/cosign_common.sh` to Cosign-sign the OCI artifact (Rekor by
  default); add the native-addon media-type constant + distinct `COSIGN_KEY_REF`. (§2.2)
  - DONE: `scripts/sign-native-addon-publish.sh` signs the published native add-on
    OCI artifact through `scripts/cosign_common.sh`; `.forgejo/workflows/native-addons.yml`
    prepares the OpenBao signing environment and sets `COSIGN_KEY_REF=hashivault://cosign-release`.
    The native bundle media types are declared in `build/native_addons/defs.bzl`, and
    `scripts/verify-native-addon-publish.sh` verifies the Cosign signature before release.
- [x] 2.2 Attach the ed25519 upload-signature with a native-addon key id; fail closed
  when signing keys are unset. (§2.3)
  - DONE differently: native add-ons do not carry a WASM-style bundle-level
    upload-signature. `build/native_addons/publish_addon.sh` signs each per-arch
    pushed-artifact tarball with the existing agent release ed25519 key via
    `//build/native_addons:addon_artifact_signature_tool`, and fails closed when
    `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` is unset. The agent verifies the same
    signature before activation.
- [x] 2.3 Generate `serviceradar-native-addon-index.json` (per-arch digests), publish
  as a release asset, and assert presence in the release job. (§2.4)
  - DONE: `scripts/generate-native-addon-import-index.sh` emits the per-arch import
    index; `.forgejo/workflows/native-addons.yml` uploads it as
    `serviceradar-native-addon-index.json` and re-queries the release to assert that
    the asset is present after upload.
- [x] 2.4 Add the verify-before-release job (digest + Cosign + upload-signature). (§2.5)
  - DONE: `.forgejo/workflows/native-addons.yml` runs
    `scripts/verify-native-addon-publish.sh` after signing. The verifier checks the
    OCI artifact type, bundle layer, Cosign signature, and every per-arch artifact
    tarball's ed25519 signature.
- [x] 2.5 Confirm no signing keys/secrets committed; only public trust material. (§2.6)
  - DONE: workflow inputs reference Forgejo secrets / OpenBao (`COSIGN_KEY_REF`,
    `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY`, registry credentials); the repository
    stores only public verification material and tooling.

## 3. Build hygiene & isolation gates
- [x] 3.1 Keep method dead-code elimination enabled with a `whydeadcode` guard; forbid
  importing the Go stdlib `plugin` package; add a per-artifact binary-size regression
  gate (`go-size-analyzer`). (§2.7)
  - DONE: forbid stdlib `plugin` — `scripts/check-addon-no-stdlib-plugin.sh`
    (`make check_addon_no_stdlib_plugin`): `go list -deps` over the agent + every
    add-on command plus a `go list` direct-import scan; fails with the offending
    package. Verified to pass clean and to fail on an injected stdlib-`plugin` import.
  - DONE: per-artifact binary-size regression gate —
    `scripts/check-addon-binary-size.sh` (`make check_addon_binary_size` and
    `make check_addon_binary_size_bazel`). CI runs it through `make addon_build_gates`
    with `REQUIRE_GSA=1`, so a missing `go-size-analyzer`/`gsa` is fatal and baseline
    overruns fail closed.
  - DONE: linker method dead-code-elimination guard —
    `scripts/check-addon-deadcode-elimination.sh` (`make check_addon_deadcode_elimination`)
    builds every Go native add-on command with `-ldflags=-dumpdep` and fails if the
    dump contains project-owned `<ReflectMethod>` roots, which is the linker explanation
    for broad method retention caused by add-on code.
- [x] 3.2 Dependency-isolation CI gate: assert (via `go list`/`goda`) the base agent's
  transitive package set excludes any add-on implementation package. (§2.8)
  - `scripts/check-addon-dependency-isolation.sh` (`make check_addon_dependency_isolation`):
    `go list -deps` on `//go/cmd/agent` asserting no add-on implementation package
    (`go/pkg/addon/sdk`, `go/cmd/serviceradar-*-addon`) is in the transitive set;
    the agent-side contract/manager packages (`go/pkg/addon`, `go/pkg/agent/addon`,
    `proto/agent/addon/v1`) are intentionally allowed. Fails with the offending import
    path. Verified to pass clean and to fail (with the path) on an injected import.

## 4. Control-plane importer
- [x] 4.1 Reuse the WASM verify-then-mirror importer (trusted-host allowlist, bounded
  fetch, digest + Cosign + upload-signature) for the native-addon index. (§4.4)
  — Done. The verify-then-persist **core** landed: `ServiceRadar.Plugins.NativeAddonImporter`
  (serviceradar_core) verifies each per-arch tarball's sha256 + the raw ed25519
  signature against the agent release key (the agent's exact `verifyAddonArtifactSignature`
  check, hex/base64 decode parity), maps the `addon.yaml` manifest + index entry to
  `AddonPackage` create attrs (kind/delivery/supervision atoms, fail-closed on unknown
  enums), and creates a **staged** package via an injected `SystemActor` (no
  `authorize?: false`). Unit-tested (verify/tamper/wrong-key/malformed, sha256, decode,
  per-arch map, attrs mapping; `mix test` green, `--warnings-as-errors` + `credo --strict`
  clean). The web-ng OCI-fetch orchestration also landed:
  `ServiceRadarWebNG.Plugins.NativeAddonImporter.import/1` resolves the repo + release
  tag, fetches `serviceradar-native-addon-index.json`, finds the entry, fetches +
  Cosign-verifies the OCI manifest, asserts each per-arch `tarball_digest`/`signature_digest`
  + the `bundle_digest` is a layer of the verified manifest and pulls those blobs by
  digest, extracts the bundle's `addon.yaml` + `config.schema.json`, assembles the per-arch
  artifacts, and calls the core `import_entry/4` with `NativeAddonArtifactMirror.mirror_fun/3`
  + a `SystemActor`. Transport (repo/release/OCI fetch, cosign, URL/digest/string utils)
  was extracted into a shared `ServiceRadarWebNG.Plugins.ForgejoOciClient`. compile
  `--warnings-as-errors` + `credo --strict` clean.
  Dedup follow-up DONE: `FirstPartyImporter` now `import ForgejoOciClient, except: [default_repo_url: 0]`
  and dropped its ~45 duplicated transport `defp`s (1006 → 470 lines); the kept code is only the
  Wasm-bundle-specific discovery/verify/result-shaping, with bare transport calls resolving to the
  shared client. `default_repo_url/0` stays a public accessor (delegating to the client) for the
  LiveView caller. Gated by the unchanged `first_party_importer_test.exs` (mocks http/cosign; drives
  every moved transport path through FPI's public API) — passes.
  E2e follow-up DONE: `native_addon_importer_test.exs` drives the full web-ng orchestration end to end
  — a fake `ForgejoOciClient` HTTP backend serves the release + `serviceradar-native-addon-index.json`
  + OCI manifest + bundle/per-arch blobs by digest, Cosign + the datasvc upload are stubbed (the upload
  via a new `:native_addon_artifact_upload` test seam), and the real core verifies sha256 + agent-release
  ed25519 and persists a staged `AddonPackage`. Covers the happy path + two fail-closed paths (wrong
  release key → `:invalid_signature`; tarball digest absent from the Cosign-verified manifest →
  `:digest_not_in_manifest`). Run via the `srql-fixtures-db-tests` scratch CNPG DB; 13/13 green.
- [x] 4.2 Mirror per-arch artifacts into ServiceRadar object storage and record the
  resolved object keys / digests / signature refs on the `AddonPackage`.
  — Done. `ServiceRadar.Plugins.NativeAddonArtifactMirror.mirror_fun/3` returns the
  `(os, arch, bytes -> {:ok, object_key})` callback `NativeAddonImporter.import_entry/4`
  takes: it uploads each verified tarball to the datasvc object store via
  `ServiceRadar.Sync.Client.upload_object` (the `ReleaseArtifactMirror` channel pattern)
  under a deterministic, traversal-safe key
  `native-addons/<addon_id>/<version>/<os>/<arch>/<sha256>.tar.gz`, and the importer
  records the resolved `{object_key, sha256, signature}` on `AddonPackage.artifacts`
  (keyed `"os/arch"`, the shape `AgentConfigGenerator` already reads). The upload fn is
  injectable; unit-tested (key/sha256/size/attributes, error propagation, segment
  sanitization). `mix test` + `--warnings-as-errors` + `credo --strict` clean.

## 5. Validation
- [x] 5.1 `openspec validate add-native-addon-build-signing --strict` passes.
- [x] 5.2 Verify-before-release rejects an unsigned/tampered artifact in CI.
  - DONE: `.forgejo/workflows/native-addons.yml` runs
    `scripts/test-verify-native-addon-publish-negative.sh` before publishing. The
    harness uses fake Bazel/ORAS/Cosign fixtures to assert
    `scripts/verify-native-addon-publish.sh` fails on a missing Cosign signature and
    on a tarball whose agent-release ed25519 signature no longer matches. The verifier
    also now fails when an artifact contains no per-arch native add-on layers.
