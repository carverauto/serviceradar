## 1. Core validation + config
- [x] 1.1 Add an operator-configurable base directory for mTLS CA material (default `/etc/serviceradar/certs`) under `EdgeOnboardingConfig`.
- [x] 1.2 Update `edgeOnboardingService.buildMTLSBundle` to read CA material from the configured base directory (not user-controlled `cert_dir`).
- [x] 1.3 Update CA cert/key path validation to use path-safe checks (for example `filepath.Rel`) and return `ErrPathOutsideAllowedDir` on escape attempts.
- [x] 1.4 Ensure invalid-path failures are returned as `models.ErrEdgeOnboardingInvalidRequest` (HTTP 400) without reading the target files.

## 2. Tests
- [x] 2.1 Add regression tests for the GH-2144 traversal attempt (`cert_dir=/etc`, `ca_cert_path=/etc/shadow`) and assert rejection.
- [x] 2.2 Add tests for allowed behavior (default cert dir; optional subdirectory inside the configured base dir).

## 3. Documentation
- [x] 3.1 Update `docs/docs/edge-onboarding.md` to document the allowed CA base directory behavior and the accepted metadata keys for mTLS onboarding.
