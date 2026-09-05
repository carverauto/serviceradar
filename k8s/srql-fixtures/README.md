# SRQL Fixture CNPG Cluster

This directory provisions the long-lived Postgres/Timescale/Apache AGE fixture used by the guarded
core integration shards and `//integration_tests/srql:{srql_api_test,srql_comprehensive_test}`.
The cluster runs in its own namespace so Forgejo and the self-hosted BuildBuddy workflow runners
can reuse one fixture while database-facing Bazel TestRunner actions execute locally on those
fixture-reachable runners.

## Contents

- `namespace.yaml` – creates the `srql-fixtures` namespace.
- `cnpg-test-credentials.yaml` – placeholder secret for the bootstrap user/password (replace before applying).
- `cnpg-test-admin-credentials.yaml` – placeholder secret for the superuser that can drop/re-create the fixture database (replace before applying).
- `cnpg-cluster.yaml` – CNPG `Cluster` spec that enables TimescaleDB + AGE using the digest-pinned `registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.4.0-sr4@sha256:59e442dec59fac3149e3a3c49ba0cc2987bfb052bca1a0ea8c01b4bb31427d1d` fixture image (`imagePullPolicy: IfNotPresent`, because Harbor has GC'd that digest before). Server TLS is user-provided from cert-manager (`srql-fixture-server-ca` / `srql-fixture-server-tls`). Pods are kept off `k8s-cp3-worker3`.
- `cert-manager.yaml` – namespace-local self-signed Issuer, 10-year CA Certificate, CA Issuer, and 90-day server Certificate.
- `ca-bundle.yaml` – Caddy static publisher for only `ca.crt` on the in-cluster ClusterIP `srql-fixture-ca-incluster`. Envoy backend only. Do not put nginx on this path.
- `httproute-ca.yaml` / `httproute-redirect.yaml` – LAN HTTPS at `https://srql-fixture-ca.carverauto.dev/ca.crt` on `lan-shared-gateway`. Let's Encrypt terminates; the custom CA is the document being served.
- `services.yaml` – exposes a `LoadBalancer` targeting the CNPG primary. It’s annotated with `metallb.universe.tf/address-pool: k3s-pool` and `metallb.universe.tf/allow-shared-ip: serviceradar-public`, so MetalLB assigns one of the public addresses already used by the demo stack (currently `23.138.124.18`). ExternalDNS also sees the `external-dns.alpha.kubernetes.io/hostname: srql-fixture.serviceradar.cloud.` annotation and creates a matching A/AAAA record. In-cluster workloads should continue using the default `srql-fixture-rw` service the operator provisions automatically.
- No network policy is applied; the LoadBalancer is publicly reachable once MetalLB advertises it. Use the shared secret/DSN guarding to control access.

## Deployment

```bash
kubectl apply -f k8s/srql-fixtures/namespace.yaml
# Copy/paste your Harbor pull secret (or re-create registry-carverauto-dev-cred) into the namespace.
kubectl -n srql-fixtures get secret registry-carverauto-dev-cred >/dev/null 2>&1 || \
  kubectl -n srql-fixtures create secret docker-registry registry-carverauto-dev-cred \
    --docker-server=registry.carverauto.dev \
    --docker-username='<harbor-username>' \
    --docker-password='<harbor-cli-secret-or-robot-token>'
# Create/update the credentials secrets before the cluster (pick your own passwords).
kubectl apply -f k8s/srql-fixtures/cnpg-test-credentials.yaml
kubectl apply -f k8s/srql-fixtures/cnpg-test-admin-credentials.yaml
kubectl apply -f k8s/srql-fixtures/cert-manager.yaml
# Wait until srql-fixture-server-ca and srql-fixture-server-tls exist before the Cluster.
kubectl apply -f k8s/srql-fixtures/cnpg-cluster.yaml
kubectl apply -f k8s/srql-fixtures/services.yaml
kubectl apply -f k8s/srql-fixtures/ca-bundle.yaml
```

### Secrets

Both secret manifests are templates. Replace the placeholder values with secure passwords or create the secrets directly:

```bash
kubectl -n srql-fixtures create secret generic srql-test-db-credentials \
  --from-literal=username=srql \
  --from-literal=password='<strong-password>'

kubectl -n srql-fixtures create secret generic srql-test-admin-credentials \
  --from-literal=username=srql_hydra \
  --from-literal=password='<strong-admin-password>'
```

### Access from CI

- The fixture enforces TLS (`hostnossl` connections are rejected). Use `sslmode=verify-full`
  with the CA certificate and the certificate's DNS server name; do not downgrade the shared
  fixture to encryption-only verification.
- Set `SRQL_TEST_DATABASE_URL` (or `SRQL_TEST_DATABASE_URL_FILE`) to the app DSN, e.g., `postgres://srql:<password>@srql-fixture-rw.srql-fixtures.svc.cluster.local:5432/srql_fixture?sslmode=verify-full`.
- Set `SRQL_TEST_ADMIN_URL` (or `SRQL_TEST_ADMIN_URL_FILE`) to the admin DSN, e.g., `postgres://srql_hydra:<password>@srql-fixture-rw.srql-fixtures.svc.cluster.local:5432/postgres?sslmode=verify-full`. The test harness uses the admin connection to drop/re-create `srql_fixture` before every run.
- Export the CA cert for strict verification (used by Rust + Elixir tests):

```bash
kubectl -n srql-fixtures get secret srql-fixture-server-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/srql-fixture-ca.crt
# LAN HTTPS (Let's Encrypt on lan-shared-gateway):
# curl -fsS https://srql-fixture-ca.carverauto.dev/ca.crt > /tmp/srql-fixture-ca.crt
export PGSSLROOTCERT=/tmp/srql-fixture-ca.crt
export SRQL_TEST_DATABASE_CA_CERT="$(cat /tmp/srql-fixture-ca.crt)"
export SRQL_TEST_DATABASE_CA_CERT_FILE=/tmp/srql-fixture-ca.crt
```
- **BuildBuddy**: `//:buildbuddy_setup_fixture_env` materializes both DSNs and the live CA into a
  private per-run file on the self-hosted in-cluster workflow runner. The CA comes from the
  cert-manager Secret when the runner has RBAC, otherwise from the LAN HTTPS bundle
  (`SRQL_FIXTURE_CA_URL`, default `https://srql-fixture-ca.carverauto.dev/ca.crt`). Do not
  store `SRQL_TEST_DATABASE_CA_CERT` in the BuildBuddy secret store, and do not mount
  fixture credentials into remote executors.
- **GitHub ARC** (`arc-runner-set` in the carverauto cluster):
  `.github/workflows/elixir-integration-sr-core.yml` sets
  `SRQL_FIXTURE_CA_URL=https://srql-fixture-ca.carverauto.dev/ca.crt`
  and keeps DSNs in GitHub Actions secrets. The runner is in-cluster, so it also resolves
  `srql-fixture-rw.srql-fixtures.svc.cluster.local`.
- **Forgejo leftover**: same `configure-srql-fixture.sh` live-CA rules while that runner is
  still in service. Do not keep a CA PEM in the Forgejo secret store.

### Maintenance

- Fixture seeding is handled by the SRQL test harness – it drops/creates schemas every run.
- Leftover scratch databases (cancelled CI clones, workstation `codex_*` / `cc_*` /
  `serviceradar_bootstrap_test_*` databases) are dropped hourly by
  `srql-fixture-scratch-reaper`. It never touches `postgres`, `srql_fixture`, or
  `sr_core_template`. Cluster YAML for the CronJob lives in gitops:
  `k8s/srql-fixtures/` (carverauto / Argo) and
  `clusters/farm01/srql-fixtures/` (farm01 / `bootstrap.sh`). Keep the
  protected-name list in sync with `go/pkg/srqlfixture/reaper` and
  `rust/integration-db`. The Go binary is `//go/cmd/tools/srql-fixture-reaper`
  (`--interval` for daemon mode; default is one pass).
- Template generations use a separate registry-owned cleanup path. Active
  BuildBuddy database workflows run `//rust/integration-db:cleanup_generations`
  before preparation. It takes the generation coordination lock and checks
  retention, leases, builders, and connections; the ordinary reaper must continue
  excluding the entire `sr_tpl_` namespace.
- If the fixture database gets wedged (for example, TimescaleDB library mismatches), reset it:

```bash
bash k8s/srql-fixtures/reset-db.sh
```

- After bumping the CNPG image tag, re-apply `cnpg-cluster.yaml` and run the reset script so extensions are recreated on the new image.
- To reset the cluster manually, delete the PVCs labeled `cnpg.io/cluster=srql-fixture` in the namespace and re-apply `cnpg-cluster.yaml`.
- Keep the CNPG image tag in sync with the Docker Compose and Helm CNPG image settings.
