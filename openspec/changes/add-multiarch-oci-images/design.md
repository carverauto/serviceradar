## Context

Six of eighteen publishable images already published a multi-arch index, and the mechanism
was already the right one: `declare_multiarch_image_index` wraps `oci_image_index`, which
transitions a single platform-aware image target across `//build/platforms:linux_x86_64` and
`linux_aarch64`. There is no separate arm64 build graph to maintain.

The hermetic-LLVM migration is what makes the rest tractable: it deleted the hand-rolled
`aarch64_linux_gnu_cc_toolchain` that hardcoded `/usr/bin/aarch64-linux-gnu-*`, so
cross-compilation now runs through the hermetic toolchain where libc is a target-platform
property. Cross-compilation of our own binaries was never the problem here.

**The problem was the layers underneath them.** Adding the six index targets produced indexes
that built successfully and were wrong. Two distinct defects, both invisible:

1. `alpine_netutils_service_image_amd64` hardcoded `base = "@alpine_3_20_linux_amd64//..."`
   and `tars = [":alpine_netutils_rootfs_amd64", ":common_tools_amd64"]`, bypassing the
   `_platform_select` its sibling helpers already used. The arm64 entry was our aarch64
   binaries on an x86-64 userland.
2. Because the image config inherits `architecture` from the base, both children of the index
   were then labelled `linux/amd64` — an index advertising the same platform twice.

Full investigation in `../../notes/archive/multiarch-oci-plan.md` (superseded on the Tier-1
assessment) and the migration it depends on in
`../../notes/archive/hermetic-llvm-rust-migration.md`.

## Goals / Non-Goals

**Goals**

- Twelve of eighteen images publishing genuinely native `linux/amd64` + `linux/arm64`.
- An eligibility rule stated over *every layer an image packages*, not just first-party
  binaries — the distinction the original audit missed.
- A test that fails when an index's contents and labels disagree.

**Non-Goals**

- arm64 for the CNPG images. Confirmed out of scope by the maintainer.
- arm64 for the Elixir images. Genuine research; tracked separately.
- Native arm64 RBE executors. Not needed for anything in this change.
- Moving `agent`, `datasvc` or `config_updater` to scratch. Reachable, but each needs
  application changes (see below) and none of them blocks arm64.

## Decisions

**Static linking was never the constraint; the userland was.** All seven Go binaries in these
images were already static — cgo is off repo-wide. So "can it be scratch?" reduces entirely to
what else the image needs. That split the six cleanly: `trivy_sidecar` and `k8s_inventory`
ship one binary, exec nothing, and are probed over HTTP, so they need no userland at all.
`datasvc` and `config_updater` have shell-script entrypoints (used by helm, not only compose),
`agent` has a `CMD-SHELL` healthcheck and a large plugin/subprocess surface, and `tools` is an
interactive bash/psql/nats shell by definition.

**Dropping the netutils bundle beat twinning it.** The obvious fix was to build an arm64
netutils rootfs. But nothing in `agent`, `trivy_sidecar`, `k8s_inventory`, `datasvc` or
`config_updater` invokes `ping`, `nmap`, `nc` or `telnet` — the bundle came from
`Dockerfile.agent` and was flattened onto every service by the macro. Worse, two of its
binaries could not execute in any of these images: `nmap` is missing four shared-library
dependencies and `telnet` is missing `libncursesw`. Deleting the bundle from those images is
less work than twinning it, ships less, and removes two binaries that were already broken.
`tools` is the one image where the bundle genuinely earns its place, and there it is twinned.

**The netprobe swap is the keystone, and it removes an otherwise permanent blocker.** The
agent packaged `//rust/netprobe:netprobe` untransitioned, which under the release platform is
a glibc-dynamic build. That is the sole reason the image carried the sgerrand
`alpine-pkg-glibc` APK and a hand-made `/lib64/ld-linux-x86-64.so.2`. That APK is x86_64-only
by design — its own APKINDEX declares `A:x86_64` and no aarch64 asset exists in any release —
so no amount of base-selector work would have produced an arm64 agent. Static-musl netprobe
already existed for both architectures with a CI assertion on its linkage; the image just
wasn't using it.

**Verification asserts ELF machine type, not manifest shape.** An index whose entries are
mislabelled passes `docker manifest inspect` and every "does it have two entries" check, then
fails on an arm64 node. `//docker/images:multiarch_index_test` therefore reads the ELF header
of the packaged binaries. It was negative-controlled: reintroducing the defect made it fail,
naming exactly the affected images.

**Alternatives considered.** Twinning the netutils rootfs for arm64 (rejected: more work,
ships broken binaries). Keeping glibc and building an aarch64 glibc APK from source (rejected:
the dependency was removable outright). Native arm64 RBE executors (rejected: unnecessary —
cross-compilation works).

## Risks / Trade-offs

- **The four ex-netutils images lose tools operators may expect interactively.** `ping` and
  `nc` remain as busybox applets in the Alpine base; `nmap` and `telnet` are gone, but neither
  could execute in these images before. If an undocumented operator workflow depended on them,
  it was already broken. → `kubectl debug` ephemeral containers.
- **`tools` on arm64 has no glibc-compat layer.** Every executable it ships is a musl APK or a
  static Go binary, and `tools-profile.sh` only prepends `/usr/glibc-compat` to
  `LD_LIBRARY_PATH` defensively. Not verified by running `ldd` inside the image. amd64 keeps
  glibc, so this risk is arm64-only. → Mitigation is that arm64 Alpine has no glibc-compat
  concept at all; anything needing it would have to be rebuilt regardless.
- **No arm64 container has been executed.** Everything here is ELF inspection of built
  artifacts. → The first arm64 deployment should be treated as a smoke test.
- **Mixed `variant` annotations**: Alpine entries are `linux/arm64/v8`, scratch entries are
  `linux/arm64`. Docker and containerd match both. → Unverified against Kyverno admission and
  the cosign flow; flagged as a follow-up rather than assumed benign.
- **cgo could be re-enabled for a Go service later**, silently making a scratch image
  unloadable. The repo-wide `pure` setting makes that a visible per-target override.

## Migration Plan

Additive for the index targets: `push_image` redirects the aggregate publish path to the index,
and repositories and tag sets are unchanged. Not purely additive for image *contents* — the
four images leaving `alpine_netutils` ship a smaller amd64 userland than before. Rollback for
any single image is reverting its `runtime` value; rollback for the publish behaviour is
dropping its `push_image` key, with no registry-side cleanup since prior tags are untouched.

## Open Questions

- Is `config_updater` still deployed? No helm template references it and compose runs a
  different script on a stock `alpine:3.20`. If it is dead, deleting it is cheaper than
  maintaining it on two architectures.
- Should `agent`, `datasvc` and `config_updater` eventually go to scratch? Each needs its
  entrypoint script's work moved into its Go binary. Worth pricing separately; none of it
  blocks arm64.
- Is arm64 a release requirement or an Apple Silicon developer convenience? It changes how
  much the remaining six images matter.
