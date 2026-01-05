# SRQL Fixture CNPG Cluster

This directory provisions the long-lived Postgres/Timescale/Apache AGE fixture that the SRQL API tests use. The cluster runs in its own namespace so BuildBuddy executors and the GitHub custom runners can reuse a single seeded database when executing `cargo test` / `bazel test //rust/srql:srql_api_test`.

## Contents

- `namespace.yaml` – creates the `srql-fixtures` namespace.
- `cnpg-test-credentials.yaml` – placeholder secret for the bootstrap user/password (replace before applying).
- `cnpg-test-admin-credentials.yaml` – placeholder secret for the superuser that can drop/re-create the fixture database (replace before applying).
- `cnpg-cluster.yaml` – CNPG `Cluster` spec that enables TimescaleDB + AGE using `ghcr.io/carverauto/serviceradar-cnpg:16.6.0-sr3`.
- `services.yaml` – exposes a `LoadBalancer` targeting the CNPG primary. It’s annotated with `metallb.universe.tf/address-pool: k3s-pool` and `metallb.universe.tf/allow-shared-ip: serviceradar-public`, so MetalLB assigns one of the public addresses already used by the demo stack (currently `23.138.124.18`). ExternalDNS also sees the `external-dns.alpha.kubernetes.io/hostname: srql-fixture.serviceradar.cloud.` annotation and creates a matching A/AAAA record. In-cluster workloads should continue using the default `srql-fixture-rw` service the operator provisions automatically.
- No network policy is applied; the LoadBalancer is publicly reachable once MetalLB advertises it. Use the shared secret/DSN guarding to control access.

## Deployment

```bash
kubectl apply -f k8s/srql-fixtures/namespace.yaml
# Copy/paste your container-registry pull secret (or re-create ghcr-io-cred) into the namespace.
kubectl -n srql-fixtures get secret ghcr-io-cred >/dev/null 2>&1 || \
  kubectl -n srql-fixtures create secret docker-registry ghcr-io-cred \
    --docker-server=ghcr.io \
    --docker-username='<gh-username>' \
    --docker-password='<ghcr-token>'
# Create/update the credentials secrets before the cluster (pick your own passwords).
kubectl apply -f k8s/srql-fixtures/cnpg-test-credentials.yaml
kubectl apply -f k8s/srql-fixtures/cnpg-test-admin-credentials.yaml
kubectl apply -f k8s/srql-fixtures/cnpg-cluster.yaml
kubectl apply -f k8s/srql-fixtures/services.yaml
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

- The fixture enforces TLS (`hostnossl` connections are rejected). Use `sslmode=require` (encryption only) or `sslmode=verify-full` with the CA certificate.
- Set `SRQL_TEST_DATABASE_URL` (or `SRQL_TEST_DATABASE_URL_FILE`) to the app DSN, e.g., `postgres://srql:<password>@srql-fixture-rw.srql-fixtures.svc.cluster.local:5432/srql_fixture?sslmode=verify-full`.
- Set `SRQL_TEST_ADMIN_URL` (or `SRQL_TEST_ADMIN_URL_FILE`) to the admin DSN, e.g., `postgres://srql_hydra:<password>@srql-fixture-rw.srql-fixtures.svc.cluster.local:5432/postgres?sslmode=verify-full`. The test harness uses the admin connection to drop/re-create `srql_fixture` before every run.
- Export the CA cert for strict verification (used by Rust + Elixir tests):

```bash
kubectl -n srql-fixtures get secret srql-fixture-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/srql-fixture-ca.crt
export PGSSLROOTCERT=/tmp/srql-fixture-ca.crt
export SRQL_TEST_DATABASE_CA_CERT=/tmp/srql-fixture-ca.crt
```
- **BuildBuddy**: Mount both DSNs into the executor pods (for example under `/var/run/secrets/srql-fixture`) and export them with `--action_env=SRQL_TEST_DATABASE_URL_FILE=/var/run/secrets/.../database_url` and `--action_env=SRQL_TEST_ADMIN_URL_FILE=...`.
- **GitHub custom runners**: Use the `srql-fixture-rw-ext` LoadBalancer IP (allocated from `k3s-pool`, currently `23.138.124.18`) or the managed DNS name `srql-fixture.serviceradar.cloud`. Add the DSNs + CA cert path as runner secrets (or files).

### Maintenance

- Fixture seeding is handled by the SRQL test harness – it drops/creates schemas every run.
- To reset the cluster manually, delete the PVCs labeled `cnpg.io/cluster=srql-fixture` in the namespace and re-apply `cnpg-cluster.yaml`.
- Keep the CNPG image tag in sync with `k8s/demo/base/spire/cnpg-cluster.yaml`.
