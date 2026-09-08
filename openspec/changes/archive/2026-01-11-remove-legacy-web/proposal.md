# Change: Remove deprecated serviceradar-web (Next.js)

## Why
The legacy `serviceradar-web` Next.js application has been fully replaced by the Phoenix-based `web-ng` UI. The legacy source code was retained "for reference" in a previous change but is no longer needed, and its lingering artifacts cause confusion. This cleanup removes all remaining traces of the deprecated web application.

## What Changes
- **BREAKING** Remove `web/` directory (legacy Next.js source code)
- Remove `build/packaging/web/` directory (legacy packaging artifacts)
- Remove `build/packaging/specs/serviceradar-web.spec` (legacy RPM spec)
- Remove `docker/compose/Dockerfile.web` (legacy Docker build)
- Remove `docker/compose/entrypoint-web.sh` (legacy entrypoint)
- Remove `docker/rpm/Dockerfile.rpm.web` (legacy RPM Docker build)
- Remove `.github/workflows/web-lint.yml` (legacy Next.js linting workflow)
- Remove `scripts/build-web-rpm.sh` (already disabled, now delete)
- Update `.github/workflows/sbom-images.yml` to remove serviceradar-web reference
- Clean up dead Makefile targets referencing legacy web

## Impact
- Affected specs: build-web-ui
- Affected code: `web/`, `build/packaging/web/`, `build/packaging/specs/`, `docker/compose/`, `docker/rpm/`, `.github/workflows/`, `Makefile`, `scripts/`
