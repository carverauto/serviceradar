ServiceRadar Kong Packaging

Overview
- Provides a wrapper package `serviceradar-kong` for Debian and RHEL that now vendors Kong Gateway OSS 3.10.0 by default for air‑gapped installs.
- Enterprise packages are still supported as a fallback: drop them into the vendor directory and they will be used automatically when present.
- Post‑install script installs the bundled upstream package locally (dpkg/rpm), so no external repos are required at install time.

Included Artifacts (copy into `packaging/kong/vendor/` before building)
- OSS (default):
  - `kong-<version>.el8.amd64.rpm` / `kong-<version>.el9.amd64.rpm` (or matching EL8/EL9 arch produced by Bazel)
  - `kong_<version>_amd64.deb` (or the matching Debian/Ubuntu arch)
- Enterprise (optional): any `kong-enterprise-edition-*.rpm` / `kong-enterprise-edition_*.deb` files you still depend on.

Build / Fetch Artifacts
- Build the OSS binaries from the upstream Kong repository (automatic helper):
  ```bash
  ./scripts/build-kong-vendor.sh
  ```
  The script clones the pinned commit (`21b0fbaafbfe835afa8998b415628610aa533cb4` by
  default), bootstraps Bazelisk for that workspace, builds the Kong runtime, and
  stages the resulting `.rpm` / `.deb` files into `packaging/kong/vendor/` with
  versioned filenames. Additional Bazel flags can be passed via
  `KONG_EXTRA_BAZEL_FLAGS`.

- Manual build fallback:
  ```bash
  git clone https://github.com/Kong/kong.git
  cd kong
  git checkout 21b0fbaafbfe835afa8998b415628610aa533cb4
  make check-bazel
  bin/bazel build --config release --//:licensing=false --//:skip_webui=true \
    //build:kong :kong_el8 :kong_el9 :kong_deb
  cp bazel-bin/pkg/kong*.rpm ../packaging/kong/vendor/
  cp bazel-bin/pkg/kong*.deb ../packaging/kong/vendor/
  ```
- To bump Kong, run the helper script with `KONG_COMMIT=<new sha>` (and
  optionally `KONG_REMOTE`) so CI and local workflows stay in sync.
- To include enterprise packages instead (or in addition), run `scripts/fetch-kong-artifacts.sh` or copy the RPM/DEB files into the same vendor directory.

Install Behavior
- Debian: `serviceradar-kong` installs the first matching `kong*.deb` package for the host architecture (falling back to any bundled `kong-enterprise-edition*.deb`) via `dpkg -i`.
- RHEL: `serviceradar-kong` installs the first matching `kong*.rpm` package for the host architecture (falling back to any bundled `kong-enterprise-edition*.rpm`) via `rpm -Uvh --nodeps`.
- No repository configuration is required on the target host.

Kong Setup Notes
- Community edition requires no license.
- For DB‑backed mode, ensure PostgreSQL reachable and set `KONG_DATABASE=postgres` and related `KONG_PG_*` env.
- For DB‑less mode, set `KONG_DATABASE=off` and `KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yml` (supply your config file).
