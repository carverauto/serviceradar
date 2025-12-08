<!-- OPENSPEC:START -->
# OpenSpec Instructions

These instructions are for AI assistants working in this project.

Always open `@/openspec/AGENTS.md` when the request:
- Mentions planning or proposals (words like proposal, spec, change, plan)
- Introduces new capabilities, breaking changes, architecture shifts, or big performance/security work
- Sounds ambiguous and you need the authoritative spec before coding

Use `@/openspec/AGENTS.md` to learn:
- How to create and apply change proposals
- Spec format and conventions
- Project structure and guidelines

Keep this managed block so 'openspec update' can refresh the instructions.

<!-- OPENSPEC:END -->

# Codex Agent Guide for ServiceRadar

This repository hosts the ServiceRadar monitoring platform. Use this file as the canonical guide when operating as a Codex agent.

## Project Overview

ServiceRadar is a multi-component system made up of Go services (core, sync, registry, poller, faker), a Rust-based SRQL service, CNPG/Timescale storage, a Next.js web UI, and supporting tooling. The repo contains Bazel and Go module definitions alongside Docker/Bazel image targets.

## Repository Layout

- `cmd/` – Go binaries (core, sync, poller, faker, kv, etc.).
- `pkg/` – Shared Go packages: identity map, registry, sync integrations, database clients.
- `rust/srql/` – SRQL translator/service backed by Diesel + CNPG.
- `docs/docs/` – User and architecture documentation (notably `architecture.md`, `agents.md`).
- `k8s/demo/` – Demo cluster manifests (faker, core, sync, CNPG, etc.).
- `docker/`, `docker/images/` – Container builds and push targets.
- `web/` – Next.js UI and API routes.
- `proto/` – Protobuf definitions and generated Go code.

## Build & Test Commands

- General Go lint/test: `make lint`, `make test`.
- Focused Go packages: `go test ./pkg/...`.
- SRQL (Rust) integration tests: `cd rust/srql && cargo test`.
- Bazel tests/images: `bazel test --config=remote //...`, `bazel run //docker/images:<target>_push`.
- Web (Next.js) lint/build: `cd web && npm install && npm run lint && npm run build` (if needed).

Prefer Bazel targets when modifying code that already has BUILD files. Always run gofmt/cargo fmt where applicable (Go formatting handled by `gofmt`, Rust by `cargo fmt`).

## Coding Guidelines

- **Go**: run `gofmt` on modified files; keep imports organized; favor existing helper utilities in `pkg/`. Avoid introducing new dependencies without updating `go.mod` and Bazel `MODULE.bazel`/`MODULE.bazel.lock` if required.
- **Rust**: run `cargo fmt` + `cargo clippy` on touched crates (notably `rust/srql`); leverage existing Diesel helpers + CNPG pooling utilities before adding new abstractions.
- **Docs**: place new operational runbooks under `docs/docs/`; keep Markdown ASCII only.

## Operational Runbooks

Reference `docs/docs/agents.md` for: faker deployment details, CNPG truncate/reseed steps, materialized view recreation, and stream replay commands. Use those instructions whenever resetting the demo environment or investigating canonical device counts.

## Common Commands & Tips

- Check demo pods: `kubectl get pods -n demo`.
- Scale sync: `kubectl scale deployment/serviceradar-sync -n demo --replicas=<n>`.
- GH client is installed and authenticated
- 'bb' (BuildBuddy) client is available for any build issues
- bazel is our build system, we use it to build and push images
- Sysmon-vm hostfreq sampler buffers ~5 minutes of 250 ms samples; keep pollers querying at least once per retention window so cached CPU data stays fresh.

## Demo Namespace Helm Refresh

- Build and push images: `make build` then `make push_all`.
- Capture the tag: `git rev-parse HEAD` and set `appTag: "sha-<sha>"` in `helm/serviceradar/values.yaml`.
- Deploy to demo: `helm upgrade --install serviceradar helm/serviceradar -n demo -f helm/serviceradar/values.yaml --atomic`.
- Sanity check: `kubectl get pods -n demo` and `helm status serviceradar -n demo`.

## Docker Compose Refresh

- Build and publish images from the current commit: `make build` then `make push_all`.
- Capture the tag for compose: `git rev-parse HEAD` and use `APP_TAG=sha-<sha>`.
- Pull fresh images: `APP_TAG=sha-<sha> docker compose pull`.
- Restart the stack: `APP_TAG=sha-<sha> docker compose up -d --force-recreate`.
- Verify: `docker compose ps` (one-shot jobs like cert-generator/config-updater exit once finished; nginx may sit in "health: starting" briefly).

## Edge Onboarding Testing with Docker mTLS Stack

Use this playbook to test edge onboarding functionality (e.g., sysmon checker mTLS bootstrap) against the Docker Compose mTLS stack.

### 1. Get Admin Credentials

The config-updater container generates admin credentials at startup:

```bash
cd docker/compose
docker compose logs config-updater 2>&1 | grep -E "(Username|Password)"
```

Look for output like:
```
Username: admin
Password: HaM5aHNMqLFA9gtq
```

### 2. Obtain a JWT Token

Authenticate against the Core API (port 8090) using the credentials:

```bash
curl -s -X POST http://localhost:8090/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<PASSWORD>"}' | jq -r '.access_token' > /tmp/jwt_token.txt
```

### 3. Find Available Pollers and Agents

```bash
# List pollers
curl -s "http://localhost:8090/api/pollers" \
  -H "Authorization: Bearer $(cat /tmp/jwt_token.txt)" | jq '.[].poller_id'

# List agents
curl -s "http://localhost:8090/api/admin/agents" \
  -H "Authorization: Bearer $(cat /tmp/jwt_token.txt)" | jq '.[].agent_id'
```

Typical output: `docker-poller` and `docker-agent`.

### 4. Create an Edge Onboarding Package

Create a checker package for the sysmon checker:

```bash
curl -s -X POST "http://localhost:8090/api/admin/edge-packages" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(cat /tmp/jwt_token.txt)" \
  -d '{
    "label": "Sysmon Test",
    "component_type": "checker",
    "component_id": "sysmon-test-01",
    "parent_id": "docker-agent",
    "parent_type": "agent",
    "poller_id": "docker-poller",
    "checker_kind": "sysmon",
    "security_mode": "mtls",
    "checker_config_json": "{\"listen_addr\":\"0.0.0.0:50083\",\"poll_interval\":30,\"filesystems\":[{\"name\":\"/\",\"type\":\"ext4\",\"monitor\":true}]}"
  }' | tee /tmp/package_response.json
```

Extract the package ID and download token:
```bash
jq -r '.package.package_id' /tmp/package_response.json
jq -r '.download_token' /tmp/package_response.json
```

### 5. Generate an Onboarding Token

Create the `edgepkg-v1:` token format (fields: `pkg`, `dl`, `api`):

```bash
PACKAGE_ID=$(jq -r '.package.package_id' /tmp/package_response.json)
DOWNLOAD_TOKEN=$(jq -r '.download_token' /tmp/package_response.json)
CORE_URL="http://localhost:8090"
TOKEN_PAYLOAD="{\"pkg\":\"$PACKAGE_ID\",\"dl\":\"$DOWNLOAD_TOKEN\",\"api\":\"$CORE_URL\"}"
echo -n "$TOKEN_PAYLOAD" | base64 -w0 | tr '+/' '-_' | tr -d '='
```

Prepend `edgepkg-v1:` to the base64 output for the final token.

### 6. Test the Sysmon Checker with mTLS Bootstrap

Ensure the certificate directory exists with proper permissions:
```bash
sudo mkdir -p /var/lib/serviceradar/checker/{certs,config}
sudo chown -R $USER:$USER /var/lib/serviceradar
```

Run the checker with the token:
```bash
export ONBOARDING_TOKEN="edgepkg-v1:<base64-token>"
./target/release/serviceradar-sysmon-checker \
    --mtls \
    --cert-dir /var/lib/serviceradar/checker/certs \
    --host http://localhost:8090
```

Successful output shows:
- "mTLS bootstrap successful"
- "Generated config at: /var/lib/serviceradar/checker/config/checker.json"
- "Certificates installed to: ..."
- "Server will listen on 0.0.0.0:50083"

### 7. Verify Generated Files

```bash
# Check certificates (key should be 0600)
ls -la /var/lib/serviceradar/checker/certs/

# View generated config
cat /var/lib/serviceradar/checker/config/checker.json | jq '.'
```

### 8. Test Restart Resilience

Restart the checker using the persisted config:
```bash
./target/release/serviceradar-sysmon-checker \
    --config /var/lib/serviceradar/checker/config/checker.json
```

### Notes

- Each package can only be downloaded once (status changes to "delivered").
- Create a new package for each test run.
- The Core API is on port 8090 (direct), Kong gateway on port 8000 (requires auth headers).
- Edge packages expire based on `download_token_ttl_seconds` (default: 10 minutes).

## Release Playbook

1. Prep metadata:
   - Update `VERSION` with the new semver (example: `1.0.54-pre1`).
   - Add a matching entry at the top of `CHANGELOG` that summarizes the release highlights.
   - Run `scripts/cut-release.sh --version <version> --dry-run` to confirm the changelog entry is detected before committing.
2. Tag the release:
   - Execute `scripts/cut-release.sh --version <version>` to stage `VERSION`/`CHANGELOG`, create the release commit, and author the annotated tag (append `--push` when you are ready to publish the refs).
3. Build and push Bazel images:
   - Authenticate to GHCR if needed: `./scripts/docker-login.sh`.
   - Run `bazel build --config=remote $(bazel query 'kind(oci_image, //docker/images:*)')` to ensure every container bakes successfully before publishing.
   - Run `bazel run --config=remote //docker/images:push_all`. This reuses the build artifacts, publishes `latest`, `sha-<commit>`, and short-digest tags, and refreshes the embedded `build-info.json`.
   - If a single image needs republishing, run `bazel run //docker/images:<target>_push` (for example `//docker/images:web_image_amd64_push`).
   - Capture the new image identifiers you care about (for example `git rev-parse HEAD` for the commit tag or the full digest printed during the push). You'll use these when refreshing Kubernetes.
4. Roll the demo namespace:
   - Restart workloads with `kubectl get deploy -n demo -o name | xargs -r -L1 kubectl rollout restart -n demo`.
   - Update any digest-pinned workloads (currently the `serviceradar-web` Deployment) so they point at the freshly pushed build, e.g. `kubectl set image deployment/serviceradar-web web=ghcr.io/carverauto/serviceradar-web:sha-$(git rev-parse HEAD) -n demo`.
   - Watch for readiness: `kubectl get pods -n demo` until all pods are `1/1` and `Running`.
5. Close out: verify the demo web UI reports the new version, file follow-up docs, and proceed with GitHub release packaging if required.

## When Updating This File

- Add new build/test commands when tooling changes.
- Keep instructions synchronized with the latest bead notes and related documentation updates.
