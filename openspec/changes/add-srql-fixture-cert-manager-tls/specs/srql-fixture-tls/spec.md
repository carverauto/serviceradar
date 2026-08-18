## ADDED Requirements

### Requirement: cert-manager issues the SRQL fixture server CA
The `srql-fixtures` namespace SHALL contain a cert-manager `Certificate` that issues a
self-signed certificate authority used only to sign the SRQL fixture Postgres server
certificate. The CA Secret name SHALL be distinct from the CNPG operator-managed
`srql-fixture-ca` Secret. The CA private key SHALL remain in that Secret and SHALL NOT be
copied into CI secret stores, workflow environment variables, or the published CA bundle.

#### Scenario: CA Certificate becomes Ready
- **GIVEN** cert-manager is installed and the `srql-fixtures` namespace exists
- **WHEN** the fixture CA `Issuer` and `Certificate` are applied
- **THEN** cert-manager SHALL write a Secret containing `ca.crt` and the CA private key
- **AND** the Certificate SHALL report Ready
- **AND** the Secret name SHALL NOT be `srql-fixture-ca`

#### Scenario: CA lifetime outlasts a server-certificate cycle
- **GIVEN** the fixture CA Certificate is Ready
- **WHEN** its duration is inspected
- **THEN** the CA `notAfter` SHALL be at least five years after `notBefore`
- **AND** `renewBefore` SHALL be at least 30 days

### Requirement: cert-manager issues the SRQL fixture server certificate
The `srql-fixtures` namespace SHALL contain a cert-manager `Certificate` that issues the
Postgres server certificate, signed by the fixture server CA. The server Secret SHALL be
type `kubernetes.io/tls` and SHALL be distinct from the CNPG operator-managed
`srql-fixture-server` Secret. The certificate SHALL include every DNS name clients and CNPG
replication use today, including `srql-fixture.serviceradar.cloud`. The server certificate
SHALL NOT be issued by a public ACME issuer.

#### Scenario: Server Certificate covers in-cluster and public DNS names
- **GIVEN** the fixture CA Issuer is Ready
- **WHEN** the server `Certificate` is applied
- **THEN** cert-manager SHALL write a `kubernetes.io/tls` Secret named differently from
  `srql-fixture-server`
- **AND** the certificate SHALL include SAN DNS names for `srql-fixture-rw`,
  `srql-fixture-r`, `srql-fixture-ro` at the in-cluster suffixes CNPG already uses
- **AND** the certificate SHALL include `srql-fixture.serviceradar.cloud`
- **AND** the certificate SHALL be signed by the fixture server CA

#### Scenario: Server certificate is short-lived and auto-renewed
- **GIVEN** the server Certificate is Ready
- **WHEN** its duration is inspected
- **THEN** duration SHALL be 90 days or less
- **AND** `renewBefore` SHALL be at least 7 days

#### Scenario: Public ACME is not used for the server certificate
- **WHEN** the server Certificate's `issuerRef` is inspected
- **THEN** it SHALL name the namespace-local fixture CA Issuer
- **AND** it SHALL NOT name `letsencrypt-dns` or any other public ACME issuer

### Requirement: CNPG uses cert-manager secrets for server TLS
The `srql-fixture` Cluster SHALL run in CNPG user-provided server-certificate mode, referencing
the cert-manager CA and server Secrets through `certificates.serverCASecret` and
`certificates.serverTLSSecret`. Both Secrets SHALL carry `cnpg.io/reload` so instances reload
on rotation. The Cluster SHALL NOT set `clientCASecret` or `replicationTLSSecret` in this
change; CNPG SHALL continue to manage the streaming-replica client certificate pair.

#### Scenario: Cluster status names the cert-manager server secrets
- **GIVEN** both cert-manager Secrets exist and are labeled for reload
- **WHEN** the Cluster is patched to `serverCASecret` / `serverTLSSecret`
- **THEN** `status.certificates.serverCASecret` and `status.certificates.serverTLSSecret`
  SHALL name those Secrets
- **AND** a TLS client using the new `ca.crt` SHALL complete `sslmode=verify-full` against
  `srql-fixture-rw.srql-fixtures.svc.cluster.local`

#### Scenario: Streaming replica stays on operator-managed client certs
- **GIVEN** the Cluster has switched to cert-manager server secrets
- **WHEN** `status.certificates` is inspected
- **THEN** `replicationTLSSecret` SHALL still name the operator-managed replication Secret
- **AND** the replica SHALL remain streaming

#### Scenario: Server certificate rotation reloads Postgres without a stored CI copy
- **GIVEN** cert-manager has renewed `srql-fixture-server-tls`
- **WHEN** CNPG observes the updated Secret
- **THEN** Postgres SHALL reload the new server certificate
- **AND** clients that still trust the fixture CA SHALL continue to verify
- **AND** no CI secret store SHALL need a manual PEM update for that server renewal

### Requirement: Fixture CA public bundle is published over public TLS
The current fixture CA certificate (`ca.crt` only) SHALL be published at a stable HTTPS URL
terminated by a publicly trusted issuer already running on the cluster. The URL SHALL be
reachable without a kubeconfig. The published object SHALL NOT contain the CA private key.

#### Scenario: Firecracker workflow can fetch the CA
- **GIVEN** the cert-manager CA Secret contains `ca.crt`
- **WHEN** a client with only the public trust store GETs the published CA URL
- **THEN** the response body SHALL be that PEM certificate
- **AND** the TLS server certificate for the URL SHALL verify against a public issuer
- **AND** the response SHALL NOT include the CA private key

#### Scenario: Published bundle tracks CA rotation
- **GIVEN** cert-manager has written a new CA certificate to the CA Secret
- **WHEN** a client GETs the published CA URL
- **THEN** the body SHALL match the new `ca.crt`

### Requirement: CI obtains the fixture CA from a live source
CI SHALL obtain `SRQL_TEST_DATABASE_CA_CERT` at the start of each database job from a live
source. That includes BuildBuddy, GitHub Actions on ARC in the carverauto cluster, and any
leftover Forgejo job. The live source is the Kubernetes CA Secret when the caller has
`get secrets` in `srql-fixtures`, otherwise a published CA bundle (HTTPS for off-cluster
runners, the in-cluster ClusterIP HTTP service for GitHub ARC). Setup SHALL still emit PEM
**content** (not a caller-owned path) into the per-run environment consumed by
`--config=database_env`. Setup SHALL fail closed if neither live source yields a current CA.
A value already present in the process environment or a CI secret store SHALL NOT be used as
the CA source.

#### Scenario: Workstation with RBAC reads the live Secret
- **GIVEN** kubectl can get secrets in `srql-fixtures`
- **WHEN** `//:buildbuddy_setup_fixture_env` runs
- **THEN** it SHALL read `ca.crt` from the cert-manager CA Secret
- **AND** the per-run env file SHALL contain that PEM as `SRQL_TEST_DATABASE_CA_CERT`
- **AND** both DSNs SHALL contain `sslmode=verify-full`

#### Scenario: Firecracker runner fetches the published bundle
- **GIVEN** the workflow runner has no kubeconfig
- **AND** the published CA URL is reachable
- **WHEN** `//:buildbuddy_setup_fixture_env` runs
- **THEN** it SHALL GET the published CA URL
- **AND** the per-run env file SHALL contain that PEM as `SRQL_TEST_DATABASE_CA_CERT`
- **AND** it SHALL NOT require `SRQL_TEST_DATABASE_CA_CERT` to be pre-set in the BuildBuddy
  secret store

#### Scenario: Stored PEM fallback is rejected
- **GIVEN** kubectl cannot read `srql-fixtures` secrets
- **AND** the published CA URL is unreachable
- **AND** `SRQL_TEST_DATABASE_CA_CERT` is already set in the environment
- **WHEN** fixture setup runs
- **THEN** it SHALL exit non-zero
- **AND** it SHALL NOT write a per-run env file that uses the pre-set PEM as the fixture CA

#### Scenario: GitHub ARC runner fetches the in-cluster bundle
- **GIVEN** a GitHub Actions job runs on `arc-runner-set` in the carverauto cluster
- **AND** `SRQL_FIXTURE_CA_URL` names the in-cluster ClusterIP CA service
- **WHEN** `scripts/ci/configure-srql-fixture.sh` runs
- **THEN** it SHALL GET that URL and emit the live PEM
- **AND** it SHALL NOT require `secrets.SRQL_TEST_DATABASE_CA_CERT`
- **AND** TestRunner actions that open the fixture SHALL stay local on that runner

#### Scenario: Forgejo leftover jobs use the same live-source rules
- **GIVEN** a Forgejo database job is still configuring the fixture
- **WHEN** `scripts/ci/configure-srql-fixture.sh` runs
- **THEN** it SHALL obtain the CA from kubectl or the published URL
- **AND** it SHALL NOT treat a stored `SRQL_TEST_DATABASE_CA_CERT` secret as the CA source

### Requirement: Fixture TLS material stays off generic remote execution
Generic remote unit-test actions SHALL NOT receive the fixture CA, fixture DSNs, or related
TLS keys in their action environment. Only invocations that explicitly select
`--config=database_env` (or the documented NATS profile for NATS material) SHALL be forwarded
those values, and those database TestRunner actions SHALL remain local to a
fixture-reachable runner.

#### Scenario: Ordinary remote sweep does not see the fixture CA
- **GIVEN** the Bazel client environment contains a fixture CA and DSNs
- **WHEN** the ordinary remote unit-test sweep runs without `database_env`
- **THEN** its TestRunner actions SHALL NOT receive `SRQL_TEST_DATABASE_CA_CERT`,
  `SRQL_TEST_DATABASE_URL`, or `SRQL_TEST_ADMIN_URL`

#### Scenario: Guarded database actions still receive PEM content
- **GIVEN** fixture setup has written the per-run env file from a live CA source
- **WHEN** a guarded database target runs with `--config=database_env` and local TestRunner
- **THEN** the action environment SHALL contain `SRQL_TEST_DATABASE_CA_CERT` as PEM content
- **AND** Elixir and Rust clients SHALL verify the server certificate with `verify-full`
  semantics and the documented server-name variables
