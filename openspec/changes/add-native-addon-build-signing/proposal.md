# Change: Native add-on build, signing & import pipeline

## Why
The agent feature-sets framework (`add-agent-feature-sets`) ratified the add-on
contract and landed the agent-sidecar spine, the control-plane catalog, and the
Bazel bundle rule. What is not yet built is the **publish-and-ingest half**: signing
add-on bundles, generating and publishing the discovery index, the verify-before-
release gate, the manifest-schema and dependency-isolation CI gates, and the
control-plane importer that mirrors signed artifacts into ServiceRadar object
storage. Until these exist, add-ons can be built but cannot be safely published or
imported, and nothing enforces that the base agent stays isolated from add-on code.

## What Changes
- Cosign-sign each native add-on OCI artifact (Rekor transparency log by default)
  with a distinct native-addon `COSIGN_KEY_REF`, and attach an ed25519
  upload-signature; **fail the build closed** when signing keys are unset.
- Generate `serviceradar-native-addon-index.json` (per-arch digests) and publish it
  as a release asset, with a release-job presence assertion.
- Add a **verify-before-release** job (digest + Cosign + upload-signature) and confirm
  no signing private keys are committed (public trust material only).
- Add a **native add-on manifest schema validator** (`addon.yaml`) and run it as a
  build/CI gate before bundling.
- Add a **dependency-isolation CI gate** (`go list`/`goda`) asserting the base
  `serviceradar-agent` transitive package set contains no add-on implementation
  package, plus the binary-size and dead-code-elimination guards from the framework.
- Add the **control-plane importer**: reuse the WASM verify-then-mirror pipeline
  (trusted-host allowlist, bounded fetch, digest + Cosign + upload-signature) over the
  native-addon index and mirror artifacts into ServiceRadar object storage.

## Impact
- **Depends on:** `add-agent-feature-sets` (framework + Bazel bundle rule) merged.
- **Affected specs:** ADDED requirements to `native-addon-builds` (manifest validation,
  dependency-isolation enforcement) and `agent-feature-sets` (importer). The framework's
  signing/index/hygiene requirements are implemented here, not redefined.
- **Affected code:** `scripts/cosign_common.sh` reuse + native-addon media-type;
  ed25519 upload-signature tooling; `build/native_addons/` sign/index rules; release +
  verify CI workflows; `goda`/`go list` and `go-size-analyzer` gates; an `addon.yaml`
  JSON-Schema + validator; `elixir/web-ng` importer (reusing the WASM importer pipeline)
  and `elixir/serviceradar_core` object-storage mirroring.
- **Needs infra:** a Cosign key ref and native-addon upload-signing secret in the
  release environment; `goda`/`go-size-analyzer` in the CI image.
