## 1. Eligibility audit

- [x] 1.1 Confirm cgo is off for the Go images. `build --@io_bazel_rules_go//go/config:pure` at `.bazelrc:65` applies repo-wide; verify no per-target `pure = "off"` or `cgo = True` override reintroduces a C dependency
- [x] 1.2 Confirm no Tier-1 image embeds a third-party amd64 binary rather than building it. `trivy_sidecar` packages our own Go wrapper, not a vendored `trivy`; `tools` packages Bazel-built CLIs
- [x] 1.3 Confirm the `agent` image's Rust payload (`netprobe`) cross-compiles — same path as the five Rust images already publishing arm64

## 2. Declare the indexes

- [x] 2.1 Add `declare_multiarch_image_index` for `agent`, `trivy_sidecar`, `k8s_inventory`, `datasvc`, `config_updater`, `tools` in `docker/images/BUILD.bazel`
- [x] 2.2 Add the matching `push_image` key to each entry in `docker/images/image_inventory.bzl`
- [ ] 2.3 Confirm `//:images` and `//:push` pick up the new index targets from the inventory without further edits

## 3. Build

- [ ] 3.1 `bazel build --config=remote` all twelve multi-arch index targets in one invocation, so the arm64 cache generation is paid once
- [ ] 3.2 Record the cold-pass cost for comparison against the amd64 baseline

## 4. Verify per architecture

- [ ] 4.1 For each of the six new indexes, confirm the manifest lists both `linux/amd64` and `linux/arm64`
- [ ] 4.2 Extract the service binary from the arm64 entry and confirm it reports an aarch64 machine type — a manifest claiming two platforms while both entries are amd64 is the failure mode this step exists to catch
- [ ] 4.3 Repeat 4.1–4.2 for one already-shipping index (`faker` or `trapd`) as a control, to prove the check can distinguish pass from fail
- [ ] 4.4 Confirm the six untouched images still publish as single-arch amd64 with unchanged tags

## 5. Record the ineligible set

- [ ] 5.1 Record the blocking payload for `cnpg`, `cnpg_analytics`, `cert_generator` (pinned amd64 Debian packages)
- [ ] 5.2 Record the blocking payload for `core_elx`, `agent_gateway`, `web_ng` (host-compiled OTP; `core_elx` additionally the amd64-only Membrane archives)

## 6. Land

- [ ] 6.1 `make test` before opening the PR
- [ ] 6.2 Open the PR against `staging` from `feat/multiarch-oci` with an explicit refspec
