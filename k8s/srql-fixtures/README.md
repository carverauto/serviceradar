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
- `cnpg-cluster.yaml` – CNPG `Cluster` spec that enables TimescaleDB + AGE using the digest-pinned `registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.4.0-sr4@sha256:e54ee02582dbb2584388c03837911c1b1cb185cea92d60d2be7a08102b5a7910` fixture image.
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

- The fixture enforces TLS (`hostnossl` connections are rejected). Use `sslmode=verify-full`
  with the CA certificate and the certificate's DNS server name; do not downgrade the shared
  fixture to encryption-only verification.
- Set `SRQL_TEST_DATABASE_URL` (or `SRQL_TEST_DATABASE_URL_FILE`) to the app DSN, e.g., `postgres://srql:<password>@srql-fixture-rw.srql-fixtures.svc.cluster.local:5432/srql_fixture?sslmode=verify-full`.
- Set `SRQL_TEST_ADMIN_URL` (or `SRQL_TEST_ADMIN_URL_FILE`) to the admin DSN, e.g., `postgres://srql_hydra:<password>@srql-fixture-rw.srql-fixtures.svc.cluster.local:5432/postgres?sslmode=verify-full`. The test harness uses the admin connection to drop/re-create `srql_fixture` before every run.
- Export the CA cert for strict verification (used by Rust + Elixir tests):

```bash
kubectl -n srql-fixtures get secret srql-fixture-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/srql-fixture-ca.crt
export PGSSLROOTCERT=/tmp/srql-fixture-ca.crt
export SRQL_TEST_DATABASE_CA_CERT="$(cat /tmp/srql-fixture-ca.crt)"
export SRQL_TEST_DATABASE_CA_CERT_FILE=/tmp/srql-fixture-ca.crt
```
- **BuildBuddy**: `//:buildbuddy_setup_fixture_env` materializes both DSNs and the CA into a private
  per-run file on the self-hosted workflow runner. The workflow sources it before Bazel starts and
  uses `--strategy=TestRunner=local`; do not mount fixture credentials into remote executors.
- **Forgejo runners**: Use the `srql-fixture-rw-ext` LoadBalancer IP (allocated from `k3s-pool`, currently `23.138.124.18`) or the managed DNS name `srql-fixture.serviceradar.cloud`. Store the DSNs and CA PEM content as runner secrets; the workflow materializes the PEM into a private temporary file when a path is required.

### Maintenance

- Fixture seeding is handled by the SRQL test harness – it drops/creates schemas every run.
- If the fixture database gets wedged (for example, TimescaleDB library mismatches), reset it:

```bash
bash k8s/srql-fixtures/reset-db.sh
```

- After bumping the CNPG image tag, re-apply `cnpg-cluster.yaml` and run the reset script so extensions are recreated on the new image.
- To reset the cluster manually, delete the PVCs labeled `cnpg.io/cluster=srql-fixture` in the namespace and re-apply `cnpg-cluster.yaml`.
- Keep the CNPG image tag in sync with the Docker Compose and Helm CNPG image settings.
