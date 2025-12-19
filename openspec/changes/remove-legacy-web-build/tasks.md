## 1. Inventory
- [ ] 1.1 Audit Bazel targets and packaging for legacy `serviceradar-web` outputs.
- [ ] 1.2 Identify all Docker Compose, Helm, K8s, and docs references to `serviceradar-web`.

## 2. Build and Publish
- [ ] 2.1 Exclude legacy `//web` targets from `bazel build //...` (keep explicit/manual targets if needed).
- [ ] 2.2 Remove/disable legacy `serviceradar-web` image/push targets and packaging outputs.

## 3. Deployment Defaults
- [ ] 3.1 Update Docker Compose defaults to use `web-ng` only (no `serviceradar-web`).
- [ ] 3.2 Update Helm/K8s manifests to deploy `web-ng` and remove legacy service wiring.

## 4. Docs and Validation
- [ ] 4.1 Update docs/runbooks to mark legacy web as deprecated and point to `web-ng`.
- [ ] 4.2 Validate `bazel build //... --config=remote` no longer builds legacy web targets.
- [ ] 4.3 Validate `bazel run //docker/images:push_all` no longer pushes legacy web tags.
