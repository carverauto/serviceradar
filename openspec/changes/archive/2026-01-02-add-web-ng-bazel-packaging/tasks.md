## 1. Toolchain & Bazel plumbing
- [ ] 1.1 Add pinned OTP/Elixir (and erlang) toolchains to `MODULE.bazel` with hermetic downloads usable on RBE.
- [ ] 1.2 Expose Node/esbuild/tailwind toolchains to Bazel for `web-ng` asset builds (reuse existing `aspect_rules_js` setup where possible).
- [ ] 1.3 Document environment variables/ci flags needed for remote builds (hex/rebar cache, npm registry auth if any).

## 2. Phoenix release targets
- [ ] 2.1 Add `web-ng/BUILD.bazel` targets that run `mix assets.build` and `mix release` for Linux (amd64; stretch goal arm64).
- [ ] 2.2 Ensure release output is a Bazel artifact (tar/zip) containing `bin/serviceradar_web_ng`, `releases/` boot scripts, and compiled assets.
- [ ] 2.3 Add a Bazel smoke rule (sh_test or similar) that boots the release with minimal env and returns health check exit code.

## 3. OCI image build
- [ ] 3.1 Create OCI rootfs layer from the Phoenix release (config, priv/static, runtime env templates).
- [ ] 3.2 Define `//docker/images:web_ng_image_amd64` with entrypoint/cmd matching the release start script and base image consistent with other services.
- [ ] 3.3 Add GHCR push target(s) and include in `push_all` / Makefile flows; capture build-info JSON like other images.

## 4. RPM/DEB packaging
- [ ] 4.1 Add `packaging/web-ng/BUILD.bazel` plus new `PACKAGES["web-ng"]` entry with package metadata, config, and systemd unit.
- [ ] 4.2 Ensure packages install release files under `/usr/local/share/serviceradar-web-ng` (or similar), drop config at `/etc/serviceradar`, and enable the service.
- [ ] 4.3 Add postinst/prerm scripts and conffiles to match existing packaging patterns; verify `rpm -ql`/`dpkg -c` coverage.

## 5. Integration & docs
- [ ] 5.1 Update release/demo runbooks (Helm/compose) to reference the new image/package tags without breaking legacy `serviceradar-web` users.
- [ ] 5.2 Add CI/bazel build targets to the pipeline (or document manual commands) so the new artifacts are built on PRs and releases.

## 6. Validation
- [ ] 6.1 Run `bazel build --config=remote` for the release tar, OCI image, RPM, and DEB to confirm toolchains work in RBE.
- [ ] 6.2 Validate container start via `bazel run //docker/images:web_ng_image_amd64.load` + `docker run` smoke script, and install rpm/deb in a Debian/EL test container.
