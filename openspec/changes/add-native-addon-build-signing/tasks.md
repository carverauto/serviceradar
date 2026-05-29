# Tasks: Native add-on build, signing & import pipeline

> Implements the publish-and-ingest half of `add-agent-feature-sets`. Task numbers in
> parentheses map back to that change's tasks.md.

## 1. Manifest validation
- [ ] 1.1 Author the `addon.yaml` manifest JSON-Schema (id, name, version, kind,
  delivery, supervision, capabilities, requires, artifacts, exec, state_dirs,
  config_schema) and a validator. (3425 §1.1)
- [ ] 1.2 Wire the validator as a build/CI gate that fails before bundling on an
  invalid `addon.yaml` or an unsupported `config.schema.json` subset.

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
- [ ] 3.2 Dependency-isolation CI gate: assert (via `go list`/`goda`) the base agent's
  transitive package set excludes any add-on implementation package. (§2.8)

## 4. Control-plane importer
- [ ] 4.1 Reuse the WASM verify-then-mirror importer (trusted-host allowlist, bounded
  fetch, digest + Cosign + upload-signature) for the native-addon index. (§4.4)
- [ ] 4.2 Mirror per-arch artifacts into ServiceRadar object storage and record the
  resolved object keys / digests / signature refs on the `AddonPackage`.

## 5. Validation
- [ ] 5.1 `openspec validate add-native-addon-build-signing --strict` passes.
- [ ] 5.2 Verify-before-release rejects an unsigned/tampered artifact in CI.
