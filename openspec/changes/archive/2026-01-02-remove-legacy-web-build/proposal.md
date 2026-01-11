# Change: Retire legacy Next.js web build outputs

## Why
The legacy `serviceradar-web` Next.js app is no longer used, but it is still built and referenced by default build and deploy workflows. This wastes build time and creates confusion alongside the new Phoenix-based `web-ng` UI.

## What Changes
- **BREAKING** Remove legacy `serviceradar-web` image/package outputs from default Bazel build and push workflows.
- Stop default Docker Compose/Helm/K8s manifests from referencing legacy `serviceradar-web` services.
- Keep `web/` sources in the repo for reference, but mark legacy build targets as explicit/manual only.

## Impact
- Affected specs: build-web-ui
- Affected code: `web/BUILD.bazel`, `docker/images/**`, `packaging/**`, `docker-compose*.yml`, `helm/serviceradar/**`, `k8s/**`, `docs/**`
