ServiceRadar Kong Packaging

Overview
- Provides a wrapper package `serviceradar-kong` for Debian and RHEL that vendors the official Kong Gateway (Community or Enterprise) packages for air‑gapped installs.
- Post‑install script installs the bundled upstream package locally (dpkg/rpm), so no external repos are required at install time.

Included Artifacts (to be downloaded before building)
- Choose one set:
  - Community: `kong-<ver>.<arch>.rpm` (EL9) and `kong_<ver>_<arch>.deb` (Debian)
  - Enterprise (optional): `kong-enterprise-edition-3.11.0.3.el9.<arch>.rpm` and `kong-enterprise-edition_3.11.0.3_<arch>.deb`

Fetch Artifacts
- Run `scripts/fetch-kong-artifacts.sh` to download the vendor packages into `packaging/kong/vendor/` (edit script if using Community URLs) prior to building the wrapper packages.

Install Behavior
- Debian: `serviceradar-kong` installs the appropriate `kong-enterprise-edition_3.11.0.3_<arch>.deb` with `dpkg -i`.
- RHEL: `serviceradar-kong` installs the appropriate `kong-enterprise-edition-3.11.0.3.el9.<arch>.rpm` with `rpm -Uvh --nodeps`.
- No repository configuration is required on the target host.

Kong Setup Notes
- Community edition requires no license.
- For DB‑backed mode, ensure PostgreSQL reachable and set `KONG_DATABASE=postgres` and related `KONG_PG_*` env.
- For DB‑less mode, set `KONG_DATABASE=off` and `KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yml` (supply your config file).
