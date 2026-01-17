# Change: Default dev deployments to latest image tags

## Why
Repeatedly updating Helm values and Docker Compose tags for every build is noisy and error-prone. We want dev/test installs to track the newest build without manual tag edits, while keeping versioned tags strictly tied to official releases.

## What Changes
- Default dev/test deployments (Helm + Docker Compose) to use `latest` image tags when no explicit tag override is provided.
- Ensure `make push_all` publishes `latest` tags for ServiceRadar images (release tagging remains versioned via `cut-release.sh`).
- Keep a single, explicit override path to pin images (e.g., `global.imageTag` / `APP_TAG`) when reproducibility is needed.

## Impact
- Affected specs: `deployment-versioning` (new).
- Affected code/config: `helm/serviceradar`, `docker-compose.yml`, build/push scripts, docs/install guidance.
