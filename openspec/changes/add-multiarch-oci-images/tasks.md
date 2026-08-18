## 1. Eligibility audit

- [x] 1.1 Confirm cgo is off for the Go binaries. `build --@io_bazel_rules_go//go/config:pure` at `.bazelrc:65` applies repo-wide; the only `cgo = True` library (`//go/pkg/cpufreq`) is darwin-guarded
- [x] 1.2 Confirm no image embeds a third-party amd64 binary rather than building it
- [x] 1.3 **Audit the base and rootfs layers, not just first-party artifacts.** This step was missing from the original plan and is what made "trivial" wrong: all six images pinned an amd64 base, an amd64 rootfs, or both
- [x] 1.4 Establish per-image what is actually needed from the userland at runtime, so "needs a real base" is distinguished from "inherited the macro default"
- [x] 1.5 Confirm upstream aarch64 availability for every pinned Alpine package (24/24 available at byte-identical version-revision) and for `natscli`

## 2. Unblock the agent (prerequisite for everything else)

- [x] 2.1 Swap the agent image's netprobe to a select over `//rust/netprobe:netprobe_linux_{x86_64,aarch64}_musl`, via an alias because the label is a dict key in `files`
- [x] 2.2 Confirm the packaged netprobe is aarch64 in the arm64 entry and x86-64 in the amd64 entry
- [x] 2.3 Confirm no `ld-linux` or glibc files remain in either entry

## 3. Route the four base-image services through the existing selector

- [x] 3.1 Move `agent`, `datasvc`, `config_updater` from `runtime = "alpine_netutils"` to `runtime = "alpine"`, which already uses `_alpine_3_20_base()` + `_common_tools_layers()`
- [x] 3.2 Delete the now-unused `alpine_netutils_service_image_amd64` helper and its dispatch branch, so the amd64-hardcoding path cannot be picked up again by a new image
- [x] 3.3 Drop glibc from the netutils bundle; it existed only to load the glibc netprobe

## 4. Scratch runtime

- [x] 4.1 Add `scratch_service_image_amd64` with `architecture` behind `_platform_select` — rules_oci requires literal `os`/`architecture` when there is no base, and the index transition does not supply them
- [x] 4.2 Add the `scratch` dispatch branch and move `trivy_sidecar` and `k8s_inventory` onto it

## 5. Make tools multi-arch

- [x] 5.1 Add `linux/arm64/v8` to the `alpine_3_24` pull and export `alpine_3_24_linux_arm64_v8` (the pinned digest already contains an arm64/v8 child, so no re-pin and no lockfile regeneration)
- [x] 5.2 Add aarch64 siblings for all 24 pinned Alpine APKs, with freshly computed sha256 values
- [x] 5.3 Add `natscli_linux_arm64`
- [x] 5.4 Parameterize `apk_rootfs` / `declare_apk_rootfs_targets` / the netutils bundle by architecture
- [x] 5.5 Put the tools base, `extra_tars` and nats binary behind selects, keeping glibc on amd64 so the amd64 debugging image is unchanged

## 6. Verify

- [x] 6.1 Build all twelve indexes in one invocation
- [x] 6.2 Confirm every index advertises both `linux/amd64` and `linux/arm64` with matching ELF machine types — 12/12 pass
- [x] 6.3 Add `//docker/images:multiarch_index_test` so this is enforced by the graph rather than by review
- [x] 6.4 **Negative control:** reintroduce the original defect (hardcode `architecture = "amd64"`) and confirm the test fails, naming exactly the affected images, then revert
- [x] 6.5 `make test` — 143 pass, 2 fail. Both failures are in `elixir/web-ng`
      (`unit_tests_phoenix_components`, `unit_tests_app_domain`) and neither is caused by this
      change, which contains no Elixir files. Confirmed by stashing the change and re-running
      `//elixir/web-ng:unit_tests_app_domain` against clean `staging` content, where it fails
      identically
- [x] 6.6 **Execute an arm64 container.** Pushed three representative indexes to a local
      registry and ran them on an Apple Silicon host with no `--platform` flag, so Docker
      selected the entry itself:
      - `tools` (heaviest, Alpine 3.24 base): `uname -m` = `aarch64`; bash reports
        `aarch64-alpine-linux-musl`; `psql` 18.4, `nats` 0.3.0 and `serviceradar-cli` all run
      - `agent` (the keystone): `uname -m` = `aarch64`; the static-musl netprobe executes and
        reports `netprobe 0.2.28`; `/lib64/ld-linux-x86-64.so.2` is absent; busybox `ping` and
        `nc` remain available after the netutils drop
      - `trivy_sidecar` (scratch, no libc and no shell): binary reaches its own config
        validation and exits 1 with `NATS_HOSTPORT is required` — an architecture or loader
        mismatch fails at exec with a different error, so this proves execution

## 7. Record the ineligible set

- [x] 7.1 `cnpg`, `cnpg_analytics` — confirmed out of scope by the maintainer; database runs on amd64
- [x] 7.2 `cert_generator` — third-party base
- [x] 7.3 `core_elx`, `agent_gateway`, `web_ng` — host-compiled OTP; `core_elx` additionally the amd64-only Membrane archives

## 8. Follow-ups not taken here

- [ ] 8.1 `config_updater` appears orphaned — no helm template references it, and compose runs a different script on a stock `alpine:3.20`. Confirm with the owner whether it should be deleted rather than maintained
- [ ] 8.2 The published set carries mixed `variant` annotations, now confirmed against a real
      registry: Alpine-based entries are `linux/arm64/v8`, scratch entries are `linux/arm64`.
      Docker selected and ran both correctly, but the demo cluster's Kyverno admission and the
      cosign signing flow were not checked against this
- [ ] 8.3 `crane push --index` of a Bazel OCI layout fails the final tag PUT against
      `registry:2`, because the layout's top-level `index.json` wraps the real index in an
      outer index-of-index. Pushing works; only the tag write fails, and tagging the inner
      digest succeeds. Worth confirming the release publish path (`oci_push`) is unaffected
      before the first multi-arch release
