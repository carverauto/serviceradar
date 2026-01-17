## Context
Dev/test iterations currently require bumping Helm values or Docker Compose tags to new git SHA tags. This slows iteration and encourages ad-hoc overrides, even though we only want versioned tags when cutting releases.

## Goals / Non-Goals
- Goals:
  - Dev/test installs should track `latest` by default with no tag edits.
  - Release installs should remain versioned and intentional via `cut-release.sh`.
  - Operators must still be able to pin tags for reproducible testing.
- Non-Goals:
  - Removing immutable tags from CI or the registry.
  - Auto-restarting workloads after every push.

## Decisions
- Default dev overlays to `latest` and set image pull policy to `Always` so new pushes are picked up on restart.
- Keep a single override path (`global.imageTag` / `APP_TAG`) for pinning.
- Ensure the build/push workflow always publishes `latest` tags alongside any existing immutable tags.

## Alternatives considered
- Using only pre-release semantic versions for dev: keeps immutability, but still requires editing tags each build.
- Automatic rollouts after push: convenient but too invasive for shared clusters.

## Risks / Trade-offs
- `latest` is mutable; debugging requires explicit pinning for reproducibility.
  - Mitigation: document the pinning path and keep immutable tags in CI.

## Migration Plan
- Update Helm dev values and Docker Compose defaults to `latest`.
- Communicate the new workflow in docs and release notes.

## Open Questions
- Should demo-staging track `latest` or remain pinned for stability?
- Do we want a `make deploy-dev` helper to rollout deployments after push?
