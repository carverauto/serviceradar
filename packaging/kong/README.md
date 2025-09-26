ServiceRadar Kong Packaging

Overview
- Provides a wrapper package `serviceradar-kong` for Debian and RHEL that now vendors Kong Gateway OSS 3.10.0 by default for air‑gapped installs.
- Enterprise packages are still supported as a fallback: drop them into the vendor directory and they will be used automatically when present.
- Post‑install script installs the bundled upstream package locally (dpkg/rpm), so no external repos are required at install time.

Included Artifacts (copy into `packaging/kong/vendor/` before building)
- OSS (default):
  - `kong.el8.amd64.rpm` (or matching EL8/EL9 arch produced by Bazel)
  - `kong.amd64.deb` (or the matching Debian/Ubuntu arch)
- Enterprise (optional): any `kong-enterprise-edition-*.rpm` / `kong-enterprise-edition_*.deb` files you still depend on.

Build / Fetch Artifacts
- Build the OSS binaries from the upstream `kong/` workspace:
  ```bash
  (cd kong && bin/bazel build --config release --//:licensing=false --//:skip_webui=true //build:kong :kong_el8 :kong_deb)
  cp kong/bazel-bin/pkg/kong*.rpm packaging/kong/vendor/
  cp kong/bazel-bin/pkg/kong*.deb packaging/kong/vendor/
  ```
- To include enterprise packages instead (or in addition), run `scripts/fetch-kong-artifacts.sh` or copy the RPM/DEB files into the same vendor directory.

Install Behavior
- Debian: `serviceradar-kong` installs the first matching `kong*.deb` package for the host architecture (falling back to any bundled `kong-enterprise-edition*.deb`) via `dpkg -i`.
- RHEL: `serviceradar-kong` installs the first matching `kong*.rpm` package for the host architecture (falling back to any bundled `kong-enterprise-edition*.rpm`) via `rpm -Uvh --nodeps`.
- No repository configuration is required on the target host.

Kong Setup Notes
- Community edition requires no license.
- For DB‑backed mode, ensure PostgreSQL reachable and set `KONG_DATABASE=postgres` and related `KONG_PG_*` env.
- For DB‑less mode, set `KONG_DATABASE=off` and `KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yml` (supply your config file).
