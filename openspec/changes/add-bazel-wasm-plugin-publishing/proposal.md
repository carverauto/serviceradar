# Change: Add Bazel-managed Wasm plugin publishing

## Why
First-party Wasm plugins are still built with ad hoc shell scripts and local `dist/` directories. They do not flow through the same Harbor publishing and Cosign signing path as the rest of the product, which makes provenance inconsistent and prevents cluster policy from enforcing the same trust contract.

## What Changes
- Add a Bazel-native build path for first-party Wasm plugin bundles.
- Publish first-party Wasm plugin bundles to Harbor as OCI artifacts with deterministic repository and tag naming.
- Sign published Wasm plugin artifacts with Cosign using the same Rekor-backed policy enforced for container images.
- Extend local verification and operator documentation so Wasm plugin artifacts can be inspected and verified before distribution.
- Align first-party plugin publication with the existing plugin bundle/import format instead of publishing loose `.wasm` files only.

## Impact
- Affected specs: `wasm-plugin-system`, `wasm-plugin-builds`
- Affected code: Bazel plugin build targets/macros, Wasm plugin examples under `go/cmd/wasm-plugins` and `go/tools/wasm-plugin-harness`, Harbor publish/sign/verify scripts, plugin docs
- Related tools: `oras` may be used for OCI artifact inspection or as an implementation detail, but Bazel remains the canonical build/publish entrypoint
