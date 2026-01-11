## 1. Source Code Removal
- [x] 1.1 Remove `web/` directory (legacy Next.js application)

## 2. Packaging Cleanup
- [x] 2.1 Remove `packaging/web/` directory
- [x] 2.2 Remove `packaging/specs/serviceradar-web.spec`

## 3. Docker Cleanup
- [x] 3.1 Remove `docker/compose/Dockerfile.web`
- [x] 3.2 Remove `docker/compose/entrypoint-web.sh`
- [x] 3.3 Remove `docker/rpm/Dockerfile.rpm.web`

## 4. CI/CD Cleanup
- [x] 4.1 Remove `.github/workflows/web-lint.yml`
- [x] 4.2 Update `.github/workflows/sbom-images.yml` to remove serviceradar-web image reference

## 5. Build System Cleanup
- [x] 5.1 Remove dead Makefile targets (build-web, deb-web, rpm-web, deb-core, rpm-core, deb-core-container, kodata-prep)
- [x] 5.2 Remove `scripts/build-web-rpm.sh`

## 6. Documentation Updates
- [x] 6.1 Update `docs/docs/web-ui.md` to remove legacy Next.js content
- [x] 6.2 Update `docs/docs/installation.md` to remove deprecation note

## 7. Validation
- [x] 7.1 Run `go build ./...` to verify Go code still compiles
- [x] 7.2 Run `make build` to verify Bazel build passes
- [x] 7.3 Verify no remaining references to legacy serviceradar-web in active code
