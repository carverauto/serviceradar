## 1. Preflight

- [ ] 1.1 Confirm live expirations still match `srql-fixture-{ca,server,replication}` at
      `2026-08-31 18:15:31 UTC` (or record the new dates if CNPG has already renewed).
- [ ] 1.2 Stop scheduling `srql-fixture` pods on `k8s-cp3-worker3` (or any node that cannot
      pull the digest-pinned Harbor CNPG image). Wait until the Cluster reports Ready `2/2`
      before any certificate cutover.
- [ ] 1.3 If this change will not be applied before `2026-08-24`, refresh the BuildBuddy and
      Forgejo `SRQL_TEST_DATABASE_CA_CERT` values from the live `srql-fixture-ca` Secret as a
      stay of execution. Do not treat that refresh as the end state.

## 2. cert-manager issuance

- [ ] 2.1 Add a namespace-local self-signed `Issuer` and a CA `Certificate`
      (`srql-fixture-server-ca`, 10-year duration, 90-day `renewBefore`) under
      `k8s/srql-fixtures/`.
- [ ] 2.2 Add a CA `Issuer` that signs from `srql-fixture-server-ca` and a server
      `Certificate` (`srql-fixture-server-tls`, 90-day duration, 15-day `renewBefore`,
      `usages: [server auth]`) with the current DNS SAN list including
      `srql-fixture.serviceradar.cloud`.
- [ ] 2.3 Label both generated Secrets `cnpg.io/reload: ""`. Do not reuse
      `srql-fixture-ca` or `srql-fixture-server`.
- [ ] 2.4 Register the new manifests in `k8s/srql-fixtures/kustomization.yaml`.
- [ ] 2.5 Apply the Issuers and Certificates. Confirm both Secrets exist and
      `cmctl status certificate` (or equivalent) is Ready before touching the Cluster.

## 3. CNPG cutover

- [ ] 3.1 Set `spec.certificates.serverCASecret` / `serverTLSSecret` on `srql-fixture` to
      the new secret names. Leave `clientCASecret` and `replicationTLSSecret` unset so CNPG
      keeps owning the streaming-replica pair.
- [ ] 3.2 Confirm `status.certificates` names the cert-manager Secrets, the running instance
      reloaded, and a `sslmode=verify-full` `psql` against
      `srql-fixture-rw.srql-fixtures.svc.cluster.local` succeeds with the new `ca.crt`.
- [ ] 3.3 Confirm streaming replication still authenticates (replica is streaming, not
      `ImagePullBackOff` or TLS-failed).

## 4. Public CA bundle

- [ ] 4.1 Publish only `ca.crt` at `https://srql-fixture-ca.serviceradar.cloud/ca.crt`
      (or the hostname recorded in design.md if DNS forces a different name), terminated by
      the cluster's existing Let's Encrypt issuer.
- [ ] 4.2 Verify the URL is reachable from outside the cluster and from a Firecracker-like
      network namespace (public DNS + public trust store, no kubeconfig).
- [ ] 4.3 Ensure the CA private key is not in the published object, the Ingress/HTTPRoute,
      or any CI secret.

## 5. CI live-source wiring

- [ ] 5.1 Change `buildbuddy_setup_fixture_env.sh` to read `srql-fixture-server-ca` via
      kubectl when RBAC exists, otherwise GET `SRQL_FIXTURE_CA_URL`. Remove the stored
      `SRQL_TEST_DATABASE_CA_CERT` fallback as a source. Keep emitting PEM content into the
      per-run env file. Fail closed if neither live source yields a current CA.
- [ ] 5.2 Change `scripts/ci/configure-srql-fixture.sh` to the same live-source rules so
      Forgejo cannot keep a stored PEM as source of truth.
- [ ] 5.3 Keep DSN secrets (`SRQL_TEST_DATABASE_URL`, `SRQL_TEST_ADMIN_URL`) as the
      password path. Continue normalizing `sslmode=verify-full`.
- [ ] 5.4 Update `buildbuddy_cache_proxy_config_test.py` so the no-kubectl case exercises
      the HTTPS (or `SRQL_FIXTURE_CA_URL`) path and asserts that a pre-set stored PEM alone
      is not enough.
- [ ] 5.5 Confirm generic remote unit-test profiles still do not forward fixture CA or DSN
      variables.

## 6. Secret-store cleanup and docs

- [ ] 6.1 After one green BuildBuddy database step against the live CA, delete
      `SRQL_TEST_DATABASE_CA_CERT` from the BuildBuddy secret store.
- [ ] 6.2 Delete the same name from the Forgejo secret store after one green Forgejo
      fixture setup (or document that Forgejo is already on the live path).
- [ ] 6.3 Update `k8s/srql-fixtures/README.md`, `rust/integration-db/README.md`,
      `.agents/skills/srql-fixtures-db-tests/SKILL.md`, `openspec/notes/bazel-bb-ci.md`,
      and the credential comments in `buildbuddy.yaml`.
- [ ] 6.4 Run `openspec validate add-srql-fixture-cert-manager-tls --strict`.
