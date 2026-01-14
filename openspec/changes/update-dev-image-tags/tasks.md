## 1. Implementation
- [ ] 1.1 Define the dev tag strategy for Helm (default latest + optional pin) and align helpers/values.
- [ ] 1.2 Update Docker Compose defaults to use `latest` when `APP_TAG` is unset.
- [ ] 1.3 Ensure `make push_all` publishes `latest` tags for ServiceRadar images.
- [ ] 1.4 Update docs/install guidance to reflect the latest-based dev workflow and explicit pinning.
- [ ] 1.5 Add validation or checks (Helm template/test or CI note) to prevent regressions.
