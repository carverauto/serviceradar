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

ServiceRadar is a multi-component system made up of Go services (core, sync, registry, agent, faker), a Rust-based SRQL service, CNPG/Timescale storage, a Next.js web UI, and supporting tooling. The repo contains Bazel and Go module definitions alongside Docker/Bazel image targets.

## Repository Layout

- `cmd/` – Go binaries (core, sync, agent, faker, kv, etc.).
- `pkg/` – Shared Go packages: identity map, registry, sync integrations, database clients.
- `rust/srql/` – SRQL translator/service backed by Diesel + CNPG.
- `docs/docs/` – User and architecture documentation (notably `architecture.md`, `agents.md`).
- `k8s/demo/` – Demo cluster manifests (faker, core, sync, CNPG, etc.).
- `docker/`, `docker/images/` – Container builds and push targets.
- `web/` – Next.js UI and API routes.
- `web-ng/` – Phoenix (next-gen) UI/API monolith.
- `proto/` – Protobuf definitions and generated Go code.

## Per-Directory Agent Guides

This file applies repo-wide, but subdirectories may include their own `AGENTS.md` with more specific rules; always read and follow the closest one to the code you are editing.

- `web-ng/AGENTS.md` – Phoenix/Elixir/LiveView/Ecto/HEEx guidelines (must follow for any `web-ng/**` changes).

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
- Sysmon-vm hostfreq sampler buffers ~5 minutes of 250 ms samples; keep gateways querying at least once per retention window so cached CPU data stays fresh.

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

## Local Development with Docker CNPG

Use this quick playbook when running `mix phx.server` locally and connecting to the CNPG instance in Docker on the same machine. This is the fastest iteration loop for testing changes.

### 1. Ensure Docker Compose is Running

Make sure CNPG is accessible on port 5455:

```bash
cd docker/compose
APP_TAG=sha-<commit> docker compose up -d cnpg
```

### 2. Copy Client Certs to a Local Directory (one-time setup)

```bash
mkdir -p .local-dev-certs
sudo cp /var/lib/docker/volumes/serviceradar_cert-data/_data/{root.pem,workstation.pem,workstation-key.pem} .local-dev-certs/
sudo chown -R $USER:$USER .local-dev-certs
```

Note: `.local-dev-certs/` is already in `.gitignore`.

### 3. Run Phoenix Locally

```bash
cd web-ng
CNPG_HOST=localhost CNPG_PORT=5455 CNPG_SSL_MODE=verify-full \
  CNPG_CERT_DIR=/home/<user>/serviceradar/.local-dev-certs \
  CNPG_TLS_SERVER_NAME=cnpg \
  mix phx.server
```

Or for local testing without network:

```bash
CNPG_HOST=localhost CNPG_PORT=5455 CNPG_SSL_MODE=verify-full \
  CNPG_CERT_DIR=$PWD/../.local-dev-certs CNPG_TLS_SERVER_NAME=cnpg \
  mix phx.server
```

### 4. Access the App

- Web UI: http://localhost:4000
- Dev Mailbox: http://localhost:4000/dev/mailbox (for testing magic links)
- Live Dashboard: http://localhost:4000/dev/dashboard

### Troubleshooting

- **Port 4000 already in use**: Kill any stale beam processes with `pkill -f beam.smp`
- **binary_to_existing_atom error**: Ensure you've run `mix compile --force` after updates

## Web-NG Remote Dev (CNPG)

Use this playbook to run `web-ng/` on a workstation while connecting to the existing CNPG instance running on the docker host (example: `192.168.2.134`).

### 1. Publish CNPG on the docker host

- By default, CNPG is bound to loopback only. To allow LAN access, set these in the docker host `.env` (or export them before running compose):
  - `CNPG_PUBLIC_BIND=0.0.0.0` (or a specific LAN interface IP)
  - `CNPG_PUBLIC_PORT=5455`

### 2. Ensure CNPG TLS cert supports IP-based clients (verify-full)

- If clients will connect by IP with `CNPG_SSL_MODE=verify-full`, add the host IP to the CNPG server cert SAN:
  - `CNPG_CERT_EXTRA_IPS=192.168.2.134`
  - Regenerate certs: `CNPG_CERT_EXTRA_IPS=192.168.2.134 docker compose up cert-generator`
  - Restart CNPG (and ensure bind env vars are applied): `CNPG_PUBLIC_BIND=0.0.0.0 CNPG_PUBLIC_PORT=5455 docker compose up -d --force-recreate cnpg`

### 3. Copy workstation client certs (keep out of git)

- Determine the cert volume name: `docker volume ls | rg 'cert-data'`
- Copy out these files from the volume to a private directory on your workstation:
  - `root.pem`
  - `workstation.pem`
  - `workstation-key.pem`

### 4. Run Phoenix from your workstation

```bash
cd web-ng
export CNPG_HOST=192.168.2.134
export CNPG_PORT=5455
export CNPG_DATABASE=serviceradar
export CNPG_USERNAME=serviceradar
export CNPG_PASSWORD=serviceradar
export CNPG_SSL_MODE=verify-full
export CNPG_CERT_DIR=/path/to/private/serviceradar-certs
mix phx.server
```

## Local mTLS ERTS Cluster (web-ng + agent-gateway)

Use this when validating TLS distribution locally without Docker. This keeps `web-ng` and `serviceradar_agent_gateway` joined over mTLS ERTS.

### 1. Generate local mTLS certs for distribution

```bash
mkdir -p tmp/serviceradar-certs tmp/ssl_dist tmp/logs
sudo CERT_DIR="$PWD/tmp/serviceradar-certs" bash docker/compose/generate-certs.sh
sudo chown -R "$USER:$USER" tmp/serviceradar-certs
```

### 2. Create ssl_dist config files that point at local cert paths

```bash
cp docker/compose/ssl_dist.web.conf tmp/ssl_dist/web.conf
cp docker/compose/ssl_dist.gateway.conf tmp/ssl_dist/gateway.conf
sed -i "s#/etc/serviceradar/certs#$PWD/tmp/serviceradar-certs#g" tmp/ssl_dist/*.conf
```

### 3. Copy Docker CNPG TLS certs for web-ng (if using local docker CNPG)

```bash
mkdir -p tmp/serviceradar-docker-certs
sudo cp /var/lib/docker/volumes/serviceradar_cert-data/_data/{root.pem,workstation.pem,workstation-key.pem} tmp/serviceradar-docker-certs/
sudo chown -R "$USER:$USER" tmp/serviceradar-docker-certs
```

### 4. Start agent gateway with TLS distribution (use 127.0.0.1 names)

```bash
ERL_FLAGS="-name serviceradar_agent_gateway@127.0.0.1 -setcookie serviceradar_dev_cookie -proto_dist inet_tls -ssl_dist_optfile $PWD/tmp/ssl_dist/gateway.conf" \
CLUSTER_ENABLED=true CLUSTER_STRATEGY=epmd \
CLUSTER_HOSTS=serviceradar_web_ng@127.0.0.1 \
ENABLE_TLS_DIST=true SSL_DIST_OPTFILE=$PWD/tmp/ssl_dist/gateway.conf \
SPIFFE_CERT_DIR=$PWD/tmp/serviceradar-certs \
GATEWAY_PARTITION_ID=local GATEWAY_ID=gateway-local-1 GATEWAY_DOMAIN=local GATEWAY_CAPABILITIES=icmp,tcp \
GATEWAY_TENANT_ID=<tenant-uuid> GATEWAY_TENANT_SLUG=platform \
nohup mix run --no-halt > $PWD/tmp/logs/gateway-local.log 2>&1 &
```

### 5. Start web-ng with TLS distribution + CNPG

```bash
ERL_FLAGS="-name serviceradar_web_ng@127.0.0.1 -setcookie serviceradar_dev_cookie -proto_dist inet_tls -ssl_dist_optfile $PWD/tmp/ssl_dist/web.conf" \
CLUSTER_ENABLED=true CLUSTER_STRATEGY=epmd \
CLUSTER_HOSTS=serviceradar_agent_gateway@127.0.0.1 \
CLUSTER_TLS_ENABLED=true SSL_DIST_OPTFILE=$PWD/tmp/ssl_dist/web.conf \
CNPG_HOST=localhost CNPG_PORT=5455 CNPG_USERNAME=serviceradar CNPG_PASSWORD=serviceradar \
CNPG_DATABASE=serviceradar_web_ng_dev CNPG_SSL_MODE=verify-ca \
CNPG_CA_FILE=$PWD/tmp/serviceradar-docker-certs/root.pem \
CNPG_CERT_FILE=$PWD/tmp/serviceradar-docker-certs/workstation.pem \
CNPG_KEY_FILE=$PWD/tmp/serviceradar-docker-certs/workstation-key.pem \
PHX_HOST=localhost SERVICERADAR_DEV_ROUTES=true SERVICERADAR_LOCAL_MAILER=true \
nohup mix phx.server > $PWD/tmp/logs/web-ng.log 2>&1 &
```

### 6. Verify cluster membership via observer node

```bash
cat > tmp/ssl_dist/observer.conf <<EOF
[{server, [
  {certfile, "$PWD/tmp/serviceradar-certs/workstation.pem"},
  {keyfile, "$PWD/tmp/serviceradar-certs/workstation-key.pem"},
  {cacertfile, "$PWD/tmp/serviceradar-certs/root.pem"},
  {verify, verify_peer},
  {fail_if_no_peer_cert, true},
  {secure_renegotiate, true},
  {depth, 2}
]},
{client, [
  {certfile, "$PWD/tmp/serviceradar-certs/workstation.pem"},
  {keyfile, "$PWD/tmp/serviceradar-certs/workstation-key.pem"},
  {cacertfile, "$PWD/tmp/serviceradar-certs/root.pem"},
  {verify, verify_peer},
  {secure_renegotiate, true},
  {depth, 2}
]}].
EOF

ERL_FLAGS="-name observer@127.0.0.1 -setcookie serviceradar_dev_cookie -proto_dist inet_tls -ssl_dist_optfile $PWD/tmp/ssl_dist/observer.conf" \
elixir -e 'IO.inspect(:rpc.call(:\"serviceradar_agent_gateway@127.0.0.1\", Node, :list, []))'
```

Note: using `@127.0.0.1` avoids the ERTS error `System running to use fully qualified hostnames` that you get with `@localhost`.

## Docker Compose mTLS ERTS (IEx/remote)

When using the Docker Compose stack, TLS distribution is enabled via `/etc/serviceradar/ssl_dist.conf` and certs live under `/etc/serviceradar/certs`.
Use the release `remote` command from inside the containers so node names resolve on the Docker network:

```bash
docker exec -it serviceradar-web-ng-mtls /app/bin/serviceradar_web_ng remote
docker exec -it serviceradar-core-elx-mtls /app/bin/serviceradar_core_elx remote
docker exec -it serviceradar-agent-gateway-mtls /app/bin/serviceradar_agent_gateway remote
```

If you need a host-side IEx shell, run a one-off container on the same Docker network with the cert volume mounted so the TLS cert paths resolve:

```bash
CERT_VOLUME=$(docker volume ls --format '{{.Name}}' | rg 'cert-data' | head -n1)
docker run --rm -it --network serviceradar-net \
  -v "${CERT_VOLUME}:/etc/serviceradar/certs" \
  ghcr.io/carverauto/serviceradar-web-ng:sha-<sha> \
  /app/bin/serviceradar_web_ng remote
```

If distribution fails with `bad_cert` or `hostname_check_failed` for `agent-gateway`, rerun `docker compose run --rm cert-generator` to refresh certs after updating `docker/compose/generate-certs.sh`.
If you see `hostname_check_failed` for `core-elx`, ensure the core certificate SAN list includes `DNS:core-elx` (and `core`, `serviceradar-core`) in `docker/compose/generate-certs.sh`, then rerun the cert generator.

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

### 3. Find Available Gateways and Agents

```bash
# List gateways
curl -s "http://localhost:8090/api/gateways" \
  -H "Authorization: Bearer $(cat /tmp/jwt_token.txt)" | jq '.[].gateway_id'

# List agents
curl -s "http://localhost:8090/api/admin/agents" \
  -H "Authorization: Bearer $(cat /tmp/jwt_token.txt)" | jq '.[].agent_id'
```

Typical output: `docker-gateway` and `docker-agent`.

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
    "gateway_id": "docker-gateway",
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
- The Core API is on port 8090 (direct); browser access goes through the edge proxy on 80/443.
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
   - If a single image needs republishing, run `bazel run //docker/images:<target>_push` (for example `//docker/images:web_ng_image_amd64_push`).
   - Capture the new image identifiers you care about (for example `git rev-parse HEAD` for the commit tag or the full digest printed during the push). You'll use these when refreshing Kubernetes.
4. Roll the demo namespace:
   - Restart workloads with `kubectl get deploy -n demo -o name | xargs -r -L1 kubectl rollout restart -n demo`.
   - Update any digest-pinned workloads (currently the `serviceradar-web-ng` Deployment) so they point at the freshly pushed build, e.g. `kubectl set image deployment/serviceradar-web-ng web-ng=ghcr.io/carverauto/serviceradar-web-ng:sha-$(git rev-parse HEAD) -n demo`.
   - Watch for readiness: `kubectl get pods -n demo` until all pods are `1/1` and `Running`.
5. Close out: verify the demo web UI reports the new version, file follow-up docs, and proceed with GitHub release packaging if required.

## When Updating This File

- Add new build/test commands when tooling changes.
- Keep instructions synchronized with the latest bead notes and related documentation updates.

## Ash First

Always use Ash concepts, almost never Ecto concepts directly. Think hard about the "Ash way" to do things. If you don't know, look for information in the rules & docs of Ash & associated packages.

When a change must remain atomic, implement `atomic/3` or refactor the action to stay atomic. Do not use `require_atomic? false` to silence atomicity warnings.

## Multitenancy Guardrails

Never propose or implement multi-tenant bypasses. Do not use Ash multitenancy bypass modes (`:bypass`, `:bypass_all`, `allow_global` overrides) or cross-tenant reads/writes. All access must remain tenant-scoped and enforced by mTLS-derived tenant identity.

## Code Generation

Start with generators wherever possible. They provide a starting point for your code and can be modified if needed.

## Logs & Tests

When you're done executing code, try to compile the code, and check the logs or run any applicable tests to see what effect your changes have had.

## Tools

Use Tidewave MCP tools, as they let you interrogate the running application in various useful ways.
- Use the `project_eval` tool to execute code in the running instance of the application. Eval `h Module.fun` to get documentation for a module or function.
- Always use `search_package_docs` to find relevant documentation before beginning work.
