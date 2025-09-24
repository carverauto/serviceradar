ServiceRadar Kong Packaging

Overview
- Provides a wrapper package `serviceradar-kong` for Debian and RHEL that vendors Kong Gateway Enterprise by default for air‑gapped installs.
- You can optionally fetch the community artifacts by setting `KONG_FETCH_COMMUNITY=1` when downloading binaries.
- Post‑install script installs the bundled upstream package locally (dpkg/rpm), so no external repos are required at install time.

Included Artifacts (download before building)
- Enterprise (default): `kong-enterprise-edition-<ver>.el9.<arch>.rpm` and `kong-enterprise-edition_<ver>_<arch>.deb`
- Community (optional): `kong-<ver>.<arch>.rpm` (EL9) and `kong_<ver>_<arch>.deb` (Debian)

Fetch Artifacts
- Run `scripts/fetch-kong-artifacts.sh` to download the enterprise binaries into `packaging/kong/vendor/`.
- Adjust the following env vars as needed:
  - `KONG_ENTERPRISE_VERSION` (default `3.11.0.3`)
  - `KONG_FETCH_COMMUNITY=1` to also pull the community artifacts (version controlled by `KONG_COMMUNITY_VERSION`, default `3.7.1`).
  - `KONG_VENDOR_DIR` if you want a different destination directory.

Install Behavior
- Debian: `serviceradar-kong` installs the appropriate `kong-enterprise-edition_<version>_<arch>.deb` (or the community `.deb` if present) with `dpkg -i`.
- RHEL: `serviceradar-kong` installs the appropriate `kong-enterprise-edition-<version>.el9.<arch>.rpm` (or the community `.rpm` if present) with `rpm -Uvh --nodeps`.
- No repository configuration is required on the target host.

Kong Setup Notes
- Community edition requires no license.
- For DB‑backed mode, ensure PostgreSQL reachable and set `KONG_DATABASE=postgres` and related `KONG_PG_*` env.
- For DB‑less mode, set `KONG_DATABASE=off` and `KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yml` (supply your config file).
