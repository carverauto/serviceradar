# Kong OSS RPM Build Plan

## Goals
- [ ] Build Kong OSS from source using Bazel so the resulting binaries match what we run in Docker Compose.
- [ ] Produce RPM packages for EL8/EL9 (and AL2/2023 variants if desired) without pulling in enterprise-only artifacts.

## Prerequisites
- [ ] Confirm build host is Linux (x86_64 or aarch64) and running as non-root. (Current host: macOS 25.0; plan to run packaging on EL builder.)
- [x] Install Bazelisk via `make check-bazel`; ensure `bin/` is on `PATH`. (bin/bazel Bazelisk v1.25.0 -> Bazel 7.3.1)
- [x] Install base toolchain and libraries from `DEVELOPER.md#build-and-install-from-source` (gcc/clang, make, git, unzip, libtool, pkg-config, etc.). (Apple CLT provides clang 17.0.0, make 3.81, pkg-config 2.5.1)
- [x] Verify `$USER` does not contain `@`; if it does, export a safe override before running Bazel. (`$USER` = mfreeman)

## Workspace Preparation
- [x] Clone Kong OSS and `cd` into the source tree. (Repo present at `kong/`)
- [ ] Prime the build cache:
  ```bash
  bazel build //build:kong --verbose_failures
  ```
  This compiles OpenResty, LuaRocks, ngx modules, and Lua deps into `bazel-bin/build/`.
  (Blocked on macOS builder: Bazel requires full Xcode; currently only Command Line Tools are installed.)

## Release Build Configuration
- [ ] Confirm `.bazelrc` `--config release` defaults (optimized build, `BUILD_NAME=kong-dev`, `INSTALL_DESTDIR=/usr/local`, no stripping).
- [ ] Add `--//:licensing=false` to keep the build OSS.
- [ ] Add `--//:skip_webui=true` to prevent `@kong_admin_gui` fetch.
- [ ] (Optional) Decide on wasm runtime flags (e.g., `--//:wasmx=false` if unused).

## RPM Packaging Targets
- [ ] Build EL8 package `:kong_el8`.
- [ ] Build EL9 package `:kong_el9`.
- [ ] (Optional) Build Amazon Linux 2 package `:kong_aws2`.
- [ ] (Optional) Build Amazon Linux 2023 package `:kong_aws2023`.

Example build (EL8):
```bash
bazel build --config release \
  --//:licensing=false \
  --//:skip_webui=true \
  :kong_el8
```

Artifacts appear under `bazel-bin/pkg/` (e.g., `kong.el8-<version>.x86_64.rpm`).

## Package Layout
- [ ] Review `build/package/nfpm.yaml` to confirm install tree under `/usr/local/kong` plus systemd/logrotate bits.
- [ ] Ensure LuaRocks tree, OpenResty, shared libraries, and default `kong.conf` align with container runtime expectations.

## Versioning
- [ ] Confirm `scripts/grep-kong-version.sh` reports desired version from `kong/meta.lua`.
- [ ] Update/tag version before packaging if necessary so RPM metadata matches release plan.

## Signing (Optional)
- [ ] Provide `RPM_SIGNING_KEY_FILE` and `NFPM_RPM_PASSPHRASE` when signed RPMs are required.

## Testing & Validation
- [ ] Install RPM in clean EL8/EL9 VM.
- [ ] Validate basic commands:
  ```bash
  sudo yum install ./kong.el8-<version>.rpm
  kong version
  kong start -c /etc/kong/kong.conf.default
  ```
- [ ] Run smoke tests that mirror Docker Compose usage (DB migrations, proxy request).

## CI Integration
- [ ] Prepare EL8/EL9 build agents with persistent Bazel cache.
- [ ] Add pipeline step to run release command and archive `bazel-bin/pkg/*.rpm` artifacts.
- [ ] (Optional) Push signed RPMs to internal repository post-validation.

## Follow-ups
- [ ] Document runtime differences between RPM install and Docker Compose stack (if any).
- [ ] Evaluate enabling wasm, simdjson, or brotli flags only when required to reduce build time.
- [ ] Track upstream Kong releases; rerun plan when `.requirements` dependencies change.
