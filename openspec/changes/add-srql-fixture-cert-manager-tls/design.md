## Context

The shared SRQL fixture is a two-instance CNPG cluster in `srql-fixtures`. Status today
(2026-08-16):

- Operator-managed secrets `srql-fixture-ca`, `srql-fixture-server`, `srql-fixture-replication`
- All three expire `2026-08-31 18:15:31 +0000 UTC` (issued 2026-06-02; 90-day CNPG default)
- `Ready=False`, `1/2` instances: `srql-fixture-2` is `ImagePullBackOff` on `k8s-cp3-worker3`
- Server SANs cover `srql-fixture-{r,ro,rw}` at every cluster-local suffix plus
  `srql-fixture.serviceradar.cloud`. No IP SANs.
- `pg_hba` is `hostssl ... scram-sha-256` (password + TLS, no client cert required)

CI consumes the CA as PEM content in `SRQL_TEST_DATABASE_CA_CERT`. That value is a snapshot
from the BuildBuddy/Forgejo secret store. `//:buildbuddy_setup_fixture_env` already prefers
`kubectl get secret srql-fixture-ca`, then falls back to the snapshot. The BuildBuddy workflow
runner is a Firecracker microVM (`k8s/buildbuddy/values-workflows.yaml`:
`enable_firecracker: true`, `default_isolation_type: oci`). It has no kubeconfig, so every BB
run takes the snapshot path.

cert-manager is already installed (`letsencrypt-dns` and several internal issuers). CNPG
documents user-provided mode with cert-manager as a first-class integration.

## Goals / Non-Goals

- Goals:
  - cert-manager owns fixture server-CA and server-cert rotation
  - CI always verifies with the CA that currently signs the server cert
  - no human-copied PEM in a CI secret store
  - no change to Elixir/Rust verify-full contract
  - Firecracker-compatible delivery (no kubectl required inside the workflow VM)
- Non-Goals:
  - minting a leaf cert per CI job
  - Let's Encrypt as the Postgres server certificate
  - client-certificate authentication for `srql` / `srql_hydra`
  - applying this issuance model to demo or production CNPG
  - putting fixture material on compile RBE workers

## Decisions

### 1. Split issuance from delivery

cert-manager solves rotation of the cluster's TLS material. It does not push into BuildBuddy.
Delivery is a second, smaller pipe: publish the public CA and have setup fetch it at job start.

### 2. cert-manager issues only the server half

Use the official CNPG user-provided server path:

- Namespace-local `Issuer` `srql-fixture-selfsigned` (`selfSigned: {}`)
- `Certificate` `srql-fixture-server-ca` (`isCA: true`, `secretName: srql-fixture-server-ca`,
  duration `87600h`, `renewBefore: 2160h`)
- Namespace-local `Issuer` `srql-fixture-ca-issuer` (`ca.secretName: srql-fixture-server-ca`)
- `Certificate` `srql-fixture-server-tls` (`secretName: srql-fixture-server-tls`, duration
  `2160h`, `renewBefore: 360h`, `usages: [server auth]`, the current DNS SAN list)

Cluster spec:

```yaml
certificates:
  serverCASecret: srql-fixture-server-ca
  serverTLSSecret: srql-fixture-server-tls
  serverAltDNSNames:
    - srql-fixture.serviceradar.cloud
```

Label both secrets `cnpg.io/reload: ""` so instances reload on rotate.

Do **not** set `clientCASecret` / `replicationTLSSecret`. CNPG keeps owning
`srql-fixture-ca` (client CA) and `srql-fixture-replication`. Today those names are shared
with the server half; after cutover they become client-only.

**Why a 10-year CA.** Clients pin the CA. A 90-day CA that rotates with the server cert is
what made a copied PEM a cliff. Server certs stay 90 days.

**Why new secret names.** If cert-manager and the operator write the same Secret, they fight.
Cut over by creating the new pair, pointing the Cluster at it, then leaving the old server
material for CNPG to drop or ignore.

**Why not Let's Encrypt for the server cert.** LE cannot issue `*.svc.cluster.local`. CNPG
replication and in-cluster DSNs need those names. The public name stays an extra SAN on the
internal CA's server cert.

**Why not a per-job CertificateRequest.** `verify-full` needs the CA that signed the *server*
certificate, not a new leaf.

### 3. The CA certificate is public; the CA key is not

`ca.crt` only allows a client to verify the fixture server. It cannot impersonate the server.
Treat it like any other internal CA bundle: publish it, do not store it next to the database
password.

The CA private key stays in `srql-fixture-server-ca` and is never mounted into CI, BB secrets,
or the workflow VM.

### 4. Live CA sources, in order

`//:buildbuddy_setup_fixture_env` and `scripts/ci/configure-srql-fixture.sh` obtain PEM
content as follows:

1. **kubectl**, when `kubectl` is on PATH and `can-i get secrets` in `srql-fixtures` succeeds.
   Read `srql-fixture-server-ca` key `ca.crt`. This is the workstation path.
2. **GET** of `SRQL_FIXTURE_CA_URL`. Defaults to
   `https://srql-fixture-ca.serviceradar.cloud/ca.crt` (Let's Encrypt) for BuildBuddy
   Firecracker. GitHub ARC runners in the carverauto cluster set
   `http://srql-fixture-ca-incluster.srql-fixtures.svc.cluster.local/ca.crt` instead: the
   ARC image has no kubectl, and granting `get` on `srql-fixture-server-ca` would also
   expose the CA private key.
3. **Fail closed.** Do not use an ambient `SRQL_TEST_DATABASE_CA_CERT` from a CI secret
   store. That is the snapshot this change deletes.

The setup target still *emits* `SRQL_TEST_DATABASE_CA_CERT` as PEM content into the private
per-run env file. That is the Bazel sandbox contract (see `rust/integration-db/README.md`).
Only the *source* of that PEM changes.

DSNs (`SRQL_TEST_DATABASE_URL`, `SRQL_TEST_ADMIN_URL`) may remain CI secrets. Passwords do not
rotate with the CA.

### 5. How the HTTPS bundle is published

A one-file publisher in `srql-fixtures` serves only `ca.crt` from the cert-manager
Secret. Public HTTPS is an HTTPRoute on `serviceradar-shared-gateway`
(`*.serviceradar.cloud` wildcard, 23.138.124.5). A dedicated MetalLB Service on
`23.138.124.18:443` is not reachable from workstations or Firecracker, so it is
not the publish path. ExternalDNS creates `srql-fixture-ca.serviceradar.cloud`
from the HTTPRoute. Gateway TLS is the shared wildcard, not the fixture CA —
otherwise fetching the CA would require the CA.

Do not install trust-manager for this change. It is the right tool for in-cluster CA
distribution later; the Firecracker VM is not in-cluster.

### 6. Keep the client TLS contract

No Elixir or Rust verify-full rewrite. `database_env` still forwards
`SRQL_TEST_DATABASE_CA_CERT` and the server-name variables. Generic remote unit tests still
must not receive them.

### 7. Replica placement before cutover

`srql-fixture-2` cannot pull
`registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.4.0-sr4@sha256:59e442dec59fac3149e3a3c49ba0cc2987bfb052bca1a0ea8c01b4bb31427d1d`
on `k8s-cp3-worker3` (the same node the BB fleets already exclude). Reloading TLS on a 1/2
Not Ready cluster is an unnecessary outage risk. Add affinity/tolerations so both instances
land on nodes that can pull Harbor, and wait for `Ready=True` before switching
`serverCASecret` / `serverTLSSecret`.

## Alternatives considered

- **Keep CNPG operator-managed certs; only refresh the BB secret.** A CronJob could PATCH the
  BB API when `srql-fixture-ca` changes. That removes the Aug 24 cliff but leaves the
  snapshot architecture Marvin asked to retire, and CNPG's CA still dies every 90 days.
- **Give the Firecracker VM a kubeconfig.** Path 1 already exists. Getting a projected SA
  token into the guest is not a documented BuildBuddy Firecracker feature. A long-lived SA
  token in BB secrets is more privileged than a CA PEM.
- **Mount the Secret into the executor pod.** Extra volumes land on the executor, not in the
  Firecracker rootfs. Rejected unless BuildBuddy grows a supported guest-mount API.
- **Long-lived CA + keep the BB PEM.** Cheap and would survive until 2036, still a snapshot.
  Used as the issuance policy, not as the delivery policy.
- **Let's Encrypt server cert + system trust store.** No custom CA in CI at all, but
  replication and in-cluster DNS names cannot be on a public certificate.

## Risks / Trade-offs

- **Cutover to user-provided secrets is one-way for the server half.** Mitigation: new secret
  names, apply Certificates first, point the Cluster only after both Secrets exist and
  `cmctl status` is Ready.
- **HTTPS CA endpoint is a new dependency for BB.** Mitigation: kubectl remains first; the
  endpoint is static content behind an existing issuer; setup fails closed rather than
  weakening TLS.
- **Publishing `ca.crt` on the public internet.** The CA signs only this fixture's server
  cert. Exposure of `ca.crt` does not grant database access. The CA key never leaves the
  Secret.
- **CNPG reload during a 1/2 cluster.** Mitigation: fix `srql-fixture-2` placement first.
- **Old BB/Forgejo CA secret left in place.** Mitigation: delete it after one green
  live-source run so a future regression cannot silently revive Path 2.

## Migration Plan

1. Fix replica placement; wait until `Cluster` is Ready `2/2`.
2. Apply self-signed Issuer, CA Certificate, CA Issuer, server Certificate. Do not edit the
   Cluster yet.
3. Confirm both new Secrets exist, SAN list matches today, CA `notAfter` is ~10 years out.
4. Stand up the HTTPS CA bundle publisher and confirm
   `curl -fsS https://srql-fixture-ca.serviceradar.cloud/ca.crt` returns that CA.
5. Patch the Cluster to the new `serverCASecret` / `serverTLSSecret`. Watch
   `status.certificates.expirations` and a `verify-full` `psql` from a workstation.
6. Land the setup-script change (kubectl then HTTPS, no stored-PEM fallback). Update the
   Python config tests.
7. Run one BB database step and one Forgejo (or equivalent) fixture setup against the live
   CA.
8. Delete `SRQL_TEST_DATABASE_CA_CERT` from the BB and Forgejo secret stores.
9. If this cannot land before 2026-08-24: refresh the stored PEM from the live Secret as a
   stay of execution, then resume the cutover. That refresh is not the end state.

Rollback: point the Cluster back at `srql-fixture-server` / `srql-fixture-ca` only if those
operator-managed secrets are still valid. After CNPG has dropped them, restore by re-applying
the cert-manager Certificates (they recreate the Secrets) and keeping user-provided mode.

## Open Questions

- Ingress vs Gateway HTTPRoute for `srql-fixture-ca.serviceradar.cloud` — pick whichever the
  `srql-fixtures` namespace can already attach to with the least new RBAC.
- Whether Forgejo runners should prefer kubectl (they may already have cluster credentials)
  or always hit the HTTPS URL. Precedence in Decision 4 covers both.
