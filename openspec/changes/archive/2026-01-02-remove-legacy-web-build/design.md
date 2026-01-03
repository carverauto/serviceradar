## Context
The Phoenix `web-ng` app is the active UI. The legacy Next.js `serviceradar-web` app remains in the repo but should not be built, packaged, or deployed by default. Current Bazel wildcard builds and deployment manifests still reference the legacy app.

## Goals / Non-Goals
- Goals:
  - Remove legacy `serviceradar-web` build and publish outputs from default workflows.
  - Ensure Docker Compose, Helm, and K8s defaults deploy `web-ng` only.
  - Keep `web/` sources available for reference without impacting builds.
- Non-Goals:
  - Deleting the `web/` directory or rewriting the Phoenix UI.
  - Changing the K8s ingress layer (Nginx ingress remains in K8s).

## Decisions
- Decision: Mark legacy Bazel targets as `manual` (or remove them from default build graph) so `bazel build //...` skips Next.js outputs.
- Decision: Remove `serviceradar-web` image/package targets from push/release workflows and deployment manifests.

## Alternatives considered
- Keep building legacy `serviceradar-web` but stop deploying it. Rejected because it wastes build time and causes confusion.

## Risks / Trade-offs
- Removing legacy artifacts may break downstream scripts relying on `serviceradar-web` images/packages. Mitigate by documenting the change and providing migration notes.

## Migration Plan
1. Update Bazel/packaging to exclude legacy outputs from default builds.
2. Update compose/helm/k8s defaults to deploy `web-ng`.
3. Update docs/runbooks and validate build/push workflows.

## Open Questions
- Should any legacy `serviceradar-web` targets remain explicitly buildable for archival purposes?
