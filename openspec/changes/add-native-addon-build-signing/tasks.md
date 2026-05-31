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
- [ ] 2.1 Reuse `scripts/cosign_common.sh` to Cosign-sign the OCI artifact (Rekor by
  default); add the native-addon media-type constant + distinct `COSIGN_KEY_REF`. (§2.2)
- [ ] 2.2 Attach the ed25519 upload-signature with a native-addon key id; fail closed
  when signing keys are unset. (§2.3)
- [ ] 2.3 Generate `serviceradar-native-addon-index.json` (per-arch digests), publish
  as a release asset, and assert presence in the release job. (§2.4)
- [ ] 2.4 Add the verify-before-release job (digest + Cosign + upload-signature). (§2.5)
- [ ] 2.5 Confirm no signing keys/secrets committed; only public trust material. (§2.6)

## 3. Build hygiene & isolation gates
- [ ] 3.1 Keep method dead-code elimination enabled with a `whydeadcode` guard; forbid
  importing the Go stdlib `plugin` package; add a per-artifact binary-size regression
  gate (`go-size-analyzer`). (§2.7)
  - DONE: forbid stdlib `plugin` — `scripts/check-addon-no-stdlib-plugin.sh`
    (`make check_addon_no_stdlib_plugin`): `go list -deps` over the agent + every
    add-on command plus a `go list` direct-import scan; fails with the offending
    package. Verified to pass clean and to fail on an injected stdlib-`plugin` import.
  - DONE (scaffold): per-artifact binary-size regression gate —
    `scripts/check-addon-binary-size.sh` (`make check_addon_binary_size`). Wired with
    a baseline + tolerance; `go-size-analyzer`/`gsa` is a CI-image PREREQUISITE (not
    installed here) — the script runs raw-size checks without it and fails closed when
    a baseline is exceeded; `REQUIRE_GSA=1` makes a missing tool fatal.
  - NOT DONE: the `whydeadcode` dead-code-elimination guard is not implemented, so this
    box stays unchecked.
- [x] 3.2 Dependency-isolation CI gate: assert (via `go list`/`goda`) the base agent's
  transitive package set excludes any add-on implementation package. (§2.8)
  - `scripts/check-addon-dependency-isolation.sh` (`make check_addon_dependency_isolation`):
    `go list -deps` on `//go/cmd/agent` asserting no add-on implementation package
    (`go/pkg/addon/sdk`, `go/cmd/serviceradar-*-addon`) is in the transitive set;
    the agent-side contract/manager packages (`go/pkg/addon`, `go/pkg/agent/addon`,
    `proto/agent/addon/v1`) are intentionally allowed. Fails with the offending import
    path. Verified to pass clean and to fail (with the path) on an injected import.

## 4. Control-plane importer
- [ ] 4.1 Reuse the WASM verify-then-mirror importer (trusted-host allowlist, bounded
  fetch, digest + Cosign + upload-signature) for the native-addon index. (§4.4)
  — Partial. The verify-then-persist **core** landed: `ServiceRadar.Plugins.NativeAddonImporter`
  (serviceradar_core) verifies each per-arch tarball's sha256 + the raw ed25519
  signature against the agent release key (the agent's exact `verifyAddonArtifactSignature`
  check, hex/base64 decode parity), maps the `addon.yaml` manifest + index entry to
  `AddonPackage` create attrs (kind/delivery/supervision atoms, fail-closed on unknown
  enums), and creates a **staged** package via an injected `SystemActor` (no
  `authorize?: false`). Unit-tested (verify/tamper/wrong-key/malformed, sha256, decode,
  per-arch map, attrs mapping; `mix test` green, `--warnings-as-errors` + `credo --strict`
  clean). Remaining: the web-ng OCI-fetch orchestration — fetch the native-addon index
  from the trusted release, bounded-fetch the bundle, Cosign-verify the OCI digest (reuse
  `CosignVerifier`), parse the bundle's `addon.yaml` + `config.schema.json`, assemble the
  per-arch fetched artifacts, and call `NativeAddonImporter.import_entry/4`.
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
- [ ] 5.2 Verify-before-release rejects an unsigned/tampered artifact in CI.
