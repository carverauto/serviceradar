# Change: Issue SRQL fixture TLS with cert-manager and stop pinning a CA PEM in CI

## Why

The `srql-fixtures` CNPG cluster (`srql-fixture` in namespace `srql-fixtures`) currently uses
operator-managed certificates. The CA and server cert were issued 2026-06-02 and both expire
**2026-08-31 18:15:31 UTC**. CNPG 1.27.1 renews operator-managed certs seven days before expiry,
so around **2026-08-24** it will rewrite `srql-fixture-ca` / `srql-fixture-server` /
`srql-fixture-replication`.

BuildBuddy and Forgejo do not read that live Secret. They inject a copied PEM as
`SRQL_TEST_DATABASE_CA_CERT` into the workflow environment. After CNPG (or any later rotation)
issues a new CA, `verify-full` fails and every Elixir/Rust fixture suite looks like a database
outage. That snapshot is leftover CI-migration scaffolding and must leave before the Bazel
renovation closes.

## What Changes

- Issue the fixture **server CA** and **server certificate** with cert-manager (already running
  on the cluster). CNPG consumes them in documented user-provided mode via
  `certificates.serverCASecret` / `serverTLSSecret`.
- Use a **long-lived CA** (10 years) and **90-day server certs** with `renewBefore` well inside
  that window. Clients pin only the CA, so server rotation is invisible to Elixir and Rust.
- Leave CNPG in charge of the **client / `streaming_replica`** pair. Do not reuse the
  operator-owned secret names `srql-fixture-ca` and `srql-fixture-server`.
- Publish the CA **public** bundle (`ca.crt` only) at a stable HTTPS URL terminated by the
  existing Let's Encrypt issuer. A CA certificate is not a secret; the CA private key never
  leaves the cluster.
- Change `//:buildbuddy_setup_fixture_env` and `scripts/ci/configure-srql-fixture.sh` to obtain
  the CA from a live source at job start: kubectl when RBAC exists, otherwise the HTTPS bundle.
  **Remove** the BuildBuddy/Forgejo stored-PEM fallback as a source of truth.
- Keep the existing test contract: `SRQL_TEST_DATABASE_CA_CERT` as PEM **content**,
  `sslmode=verify-full`, `SRQL_TEST_DATABASE_SERVER_NAME` / `PGSSLSERVERNAME`. DSNs and passwords
  may remain CI secrets.
- Do not put the CA (or DSNs) into generic remote RBE action environments.
- Document the cutover and delete `SRQL_TEST_DATABASE_CA_CERT` from the BuildBuddy and Forgejo
  secret stores after the live path is green.

## Non-Goals

- Per-job `CertificateRequest` objects from CI.
- Let's Encrypt as the CNPG server certificate (cannot cover `*.svc.cluster.local`).
- Replacing password auth with client-cert auth for fixture users.
- Changing the guarded Bazel lifecycle, shard model, or `database_env` forwarding boundary.
- Extending this issuance model to demo/production CNPG in this change.
- Putting fixture credentials on the compile RBE fleet.

## Impact

- Affected specs:
  - `srql-fixture-tls` (new)
- Affected code and operations:
  - `k8s/srql-fixtures/` (Issuer, Certificates, Cluster `certificates:`, CA bundle publisher,
    kustomization, README)
  - `k8s/srql-fixtures/cnpg-cluster.yaml` (user-provided server secrets; replica placement so
    cert reload is not done on a 1/2 Not Ready cluster)
  - `buildbuddy_setup_fixture_env.sh` and `scripts/ci/configure-srql-fixture.sh`
  - `buildbuddy_cache_proxy_config_test.py` (Path 2 stored-PEM tests)
  - `buildbuddy.yaml` comments
  - `rust/integration-db/README.md`
  - `.agents/skills/srql-fixtures-db-tests/SKILL.md`
  - `openspec/notes/bazel-bb-ci.md`
  - BuildBuddy and Forgejo secret-store contents (delete the CA PEM)
- Operational impact:
  - Must land before 2026-08-24 or refresh the stored PEM as a stay of execution.
  - `srql-fixture-2` is `ImagePullBackOff` on `k8s-cp3-worker3`; fix placement before TLS
    cutover so the cluster is not a single replica during reload.
  - Tightens the fixture CA contract introduced in
    `route-bazel-cache-through-shared-edge` without rewriting that cache-routing spec.
