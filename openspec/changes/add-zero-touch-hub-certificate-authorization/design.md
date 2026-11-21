## Context

Facts this design rests on, from the tree at the time of writing:

- The broker configuration is a shell heredoc in the NATS container arguments
  (`helm/serviceradar/templates/nats.yaml:153-268`). There is no included file
  and no reload path, so any change to it is a StatefulSet rollout.
- The callout needs three public nkeys in that configuration: the issuer
  account key, and the user keys of the two connections core's authorizer
  opens (`AUTH` and `SYS`).
- Core's authorizer (`ServiceRadar.NATS.ManagedCertificateAuthorization`)
  connects with those nkey users, so it does not itself pass through the
  callout. It admits a certificate when the fingerprint is adopted, unrevoked
  and has a stored grant; for a chart identity it then applies the chart's
  static permission block from the static users file, not the stored grant.
- The certificate generator job creates every certificate into one Secret and
  regenerates all of them when the layout version changes or a required file
  is missing. Each pod mounts only its own certificate and `root.pem`. Core's
  Role cannot read Secrets or ConfigMaps.
- When the generator reissues certificates it writes
  `runtime-cert-rotation.json` (public certificates and the fingerprints they
  replace, no key material) into the runtime Secret.
  `ServiceRadar.Edge.RuntimeCertificateRotation` records each reissued
  certificate as the successor of an adopted predecessor, from the core
  migrations hook before workloads roll and again on a 30 second reconcile. A
  certificate whose predecessor was never adopted is skipped.
- Three static users (`serviceradar-flowgger`, `serviceradar-otel`,
  `serviceradar-netflow-collector`) have no certificate of their own; their
  files are copies of another identity's certificate. One static user,
  `O=ServiceRadar` (publish allow `>` with deny `logs.normalized.>`, subscribe
  allow `>`), matches no chart-generated certificate.
- `edge install leaf` proceeds when the hub authorizer is not connected.
- The address new edge-site leaves dial comes from
  `SERVICERADAR_NATS_LEAF_UPSTREAM_URL`, which the chart renders only on the
  web-ng pod, the only workload that receives it, and only when a leaf host
  (`hostedRuntime.publicEndpoints.natsLeafHost`) is set. Web-ng copies it into
  the application env only when it is non-empty. Core never has it. When it is
  unset the edge site code falls back to a hard-coded hosted address.

A chart identity, for this capability, is a subject for which the generator
issues a distinct NATS client certificate. The three alias users and
`O=ServiceRadar` are not chart identities: they are not counted in adoption
coverage and never block the leaf install gate.

## Goals / Non-Goals

- Goals: no hand adoption of chart identities; no pasted keys; one setting;
  safe to turn on; survives certificate regeneration; the operator can see
  hub readiness before installing a leaf.
- Non-Goals: changing how host-enrolled components, leaves or collectors are
  admitted; changing revocation; Compose and packaged hubs; edge account
  isolation; network exposure of the leaf port.

## Decisions

### Decision 1: The chart publishes its public certificates; core adopts them

The inventory is a read-only projection, into core, of the public certificate
file of each chart identity from the runtime certificate Secret. Every
workload already mounts that Secret through an explicit item list
(`serviceradar.runtimeCertItems`), so a pod sees only the files named for it;
core's list gains the public `.pem` of each chart identity and no `-key.pem`.
The precedent is `runtime-cert-rotation.json`, a key of the same Secret that
core already mounts this way. No ConfigMap is created, the generator job is
not changed for this, and its Role is unchanged.

This was chosen over a separate ConfigMap written by the generator, which an
earlier draft proposed: that needed new write permissions for the job, a new
step on the path where the generator finds existing certificates and exits
early, and a second object the hosted control plane would have to supply.

A required Secret volume fails to mount when a listed key is missing, and a pod with a
failed mount does not start. On a chart install the generator always creates
every chart identity's certificate. A Secret supplied by the hosted control
plane may not carry the same files, so in hosted mode the list of inventory
certificate files is a chart value the control plane sets to what it supplies (task 2.7),
and that inventory list defaults to empty.

Core reconciles on the authorizer's existing tick. Each certificate in the
inventory is checked first:

- it chains to the deployment `root.pem` that core already mounts;
- it is within its validity period;
- its subject is a chart identity with a static user in the static users file;
- its fingerprint is not revoked.

A certificate that fails a check is reported with the reason and nothing is
written. Adoption is one ordered rule:

1. If any infrastructure certificate row lacks a stored subject (see below),
   the inventory adopts nothing and reports that state with the remedy.
2. Otherwise, for each qualifying certificate whose subject is not held, core
   creates the component, with a component id derived from the subject only
   and that subject's static grant as its stored permissions, and records the
   certificate with its subject. When the subject is held, the inventory
   writes nothing.

"Held" must be computable from stored rows, and today it is not: a recorded
certificate stores fingerprint, issuer, serial, generation, role and validity,
but neither its subject nor its PEM, and a hand-adopted component's id is
chosen by the operator. This change therefore:

- adds a subject to the certificate record, written whenever a certificate is
  recorded (inventory adoption, hand adoption, successor and rotation
  recording), from the PEM available at that moment;
- gives a component created by the inventory a deterministic component id
  derived from the chart identity's subject;
- defines a subject as **held** when any recorded certificate, on any
  component and whether or not it is revoked or superseded, carries that
  subject. First adoption applies only when the subject is not held.

Rows recorded before this change have no subject and cannot be backfilled,
because the PEM was not stored. While any infrastructure component has a
recorded certificate without a subject, the inventory adopts nothing and
reports that state with the remedy: record those certificates again through
the existing adoption API, or remove the component. No install is known to
have adopted infrastructure, so this set is expected to be empty in practice;
task 1.4 checks live deployments.

Replacement of an adopted certificate stays solely with the existing
`ServiceRadar.Edge.RuntimeCertificateRotation` path driven by
`runtime-cert-rotation.json`, unchanged by this change, including its refusal
when the predecessor is revoked, superseded or from another issuer. A subject
whose certificate was revoked therefore stays refused until an operator acts,
as today. One residual case is not covered by either path: when the rotation
manifest's predecessor is an unrecorded intermediate certificate while an
older certificate of that subject is recorded, the rotation path skips it and
the subject is held, so neither path records the current certificate. The
identity is reported unadopted with that reason, and an operator records the
successor through the existing API. This is fail-closed and visible.

Coverage: a chart identity counts as adopted when the inventory's certificate
for that subject is recorded and not revoked. Otherwise it is reported with
the reason: a failed check, legacy rows without a subject, or a held subject
whose recorded certificates do not include the inventory's certificate (for
example after a refused rotation, a revocation, or the residual case above).

The stored grant is the static block for that subject. It is only the
per-fingerprint record: admission of a chart identity still uses the static
users file, and a missing or unread static file still refuses it.

A certificate that chains to the root and carries a
chart subject is already accepted by the broker today through
`verify_and_map`. Changing the files core reads needs write access to the
runtime certificate Secret. Revoked certificates remain ineligible for adoption.

This provides the first adoption of chart certificates, which the existing
rotation record cannot: it only records successors of certificates already
adopted, and skips the rest. The inventory complements that record and does
not replace it. The rotation record keeps handling replacements of
already-adopted certificates before workloads roll; the inventory performs
first adoption only.

Hand adoption (`POST /managed-components/adopt`) stays, unchanged, for clients
the chart does not define.

Alternatives considered:
- A CLI command that reads the runtime Secret and calls adopt per certificate.
  Rejected: it needs Kubernetes access to every component's private key, it
  is not available to a hosted tenant, and it does not survive regeneration.
- Give core RBAC to read the Secret. Rejected: core would hold every
  component's private key.
- Admit chart subjects by subject alone, with no adoption record. Rejected:
  the existing design keeps a per-fingerprint record so one certificate can be
  revoked and used certificates can be listed; this keeps that.

### Decision 2: Signing key provisioning follows issuer Secret ownership

Compare the Secret names resolved by `serviceradar.runtimeIssuerSecretName`
and `serviceradar.runtimeCertsSecretName`. When they match (the self-managed
default), the runtime Secret already holds the CA key. On every run,
including before the existing-certificate early exit, the generator inspects
the three signing seeds and two public broker fragments in that Secret.

- If all five entries are absent, generate the issuer, auth and system seeds
  and publish them together with both fragments derived from their public keys.
- If all three seeds are present, preserve them and rebuild only missing or
  stale fragments from those seeds. A matching set needs no write.
- If any signing entry remains but a seed is missing, fail the job without
  writing. Name each missing seed and direct the operator to restore it or
  deliberately remove all remaining signing entries to provision a new set.

Signing key rotation is outside this change.

When `certs.issuerSecretName` resolves to a distinct Secret, its owner
provisions the three seeds there and both matching fragments in the runtime
Secret. This applies to self-managed and hosted installs. The generator
leaves all five entries alone on install, upgrade and certificate regeneration.
Its Role stays unchanged. The chart documents all five required Secret keys
and their destinations.

With enforcement enabled, the chart renders two fixed signing projections.
Core mounts the three issuer Secret seeds in a separate optional volume so
it can start and report a missing seed. NATS requires both runtime Secret
fragments. When either is missing, Kubernetes blocks the affected pod at
startup and names the missing key in its mount event, regardless of core's
seeds. Core checks its mounted seeds first. If any is missing, hub status
reports `signing keys not provisioned` even during a broker outage.
With all seeds mounted, if core keeps answering
through another broker, an otherwise ready hub stays ready and leaf install
proceeds. If the seeds are present but core loses its authorizer connection, hub status reports the
authorizer is not answering and leaf install stops. The runbook directs
operators to the affected pod's events when checking NATS and core health.
With enforcement disabled the chart omits both signing projections.

On hosted installs the distinct issuer Secret holds both the CA signing key
and the callout seeds. Pod projections limit the files mounted into workloads. In either mode, Kubernetes principals with read
access to the issuer Secret can read the seeds and use the signing keys.

A broker experiment confirmed that nats-server accepts the callout
authorization from an included file at the top level and the two extra
accounts from a file included inside the accounts block, and that empty
fragments leave the static configuration as it is today. With enforcement off
the NATS pod includes nothing.

On chart installs core uses the three mounted seeds. The broker fragments
carry their public keys. Core ignores any database signing record and logs
once that the record is unused. An incomplete or absent seed mount with
enforcement enabled still yields `signing keys not provisioned`. Only installs
without a chart use the database record and the bootstrap API.

Why not keep the keys in the database and copy public keys into values: that
copy is the hand step being removed, and Helm cannot read the database at
render time.

For hosted tenants the control plane adds the seeds to its existing issuer
Secret and the fragments to its existing runtime certificate Secret. It
sets only the inventory certificate list to the files it supplies. This is tracked in
`serviceradar-control`.

### Decision 3: One value, and the unverifiable promise is removed

`nats.certificateAuthorization.enabled` is the only setting. The chart no
longer asks the operator to assert `infrastructureAdopted`; adoption is
automatic and its coverage is reported by core (Decision 5). The three key
values are removed.

This is a chart value, and the control plane renders the same value for
tenants, so it is not a Helm-only switch.

The chart keeps refusing `nats.certificateAuthorization.enabled` together
with `certs.regenerator.enabled`. The regenerator mints a new root and writes
no rotation manifest, so its certificates could be neither rotated onto nor
first-adopted (their subjects are held). Only `infrastructureAdopted` and the
three key values are removed; that exclusion stays. Adoption under a new root
is out of scope.

### Decision 4: Default (owner decision)

With enforcement on, a new NATS connection is admitted only if core's
authorizer answers, which needs core and its database. Established sessions
continue until their grant expires. The authorizer's own connections do not
depend on the callout, so the system can start from cold: NATS, then core,
then everything else connects or retries.

- **Off by default for this release (proposed).** Self-managed installs that
  do not use leaves keep today's behaviour. The hosted control plane turns it
  on for tenants. Demo runs with it on, so it is exercised continuously.
  Revisit the default once it has run there.
- **On by default.** Leaf onboarding needs nothing on the hub at all, but
  every install takes the availability dependency, including ones with no
  edge sites.

### Decision 5: Readiness is reported, and the CLI stops early

`GET /api/admin/managed-components/bootstrap` gains a `hub` object:

- `enforcement_configured`: whether the install was rendered with
  `nats.certificateAuthorization.enabled`. Core cannot inspect the chart, so
  the chart tells it through a rendered setting, like the leaf listener;
- `authorizer_answering`: whether core's authorizer is connected and
  answering the broker, with the readiness reason when it is not;
- `chart_identities`: total, adopted, and the subjects not adopted with the
  reason for each;
- `leaf_listener`: whether the hub broker is configured with the leafnodes
  listener. Core cannot inspect the broker configuration, so the chart tells
  it through a setting rendered from `nats.leafnodes.enabled` together with
  enforcement, the same condition under which the chart renders the listener;
- `leaf_upstream_url`: whether the address new edge-site leaves dial is
  configured for this install. This is decided in web-ng, the only workload
  that receives `SERVICERADAR_NATS_LEAF_UPSTREAM_URL`, by reading the
  application env without a default; the key is set only when the variable is
  non-empty. The hard-coded hosted fallback used when it is unset is not
  treated as configured.

`enforcement_configured`, `authorizer_answering`, `chart_identities` and
`leaf_listener` are decided on core. The bootstrap route is served by web-ng,
which assembles the `hub` object from core's fields and its own
`leaf_upstream_url`.

`serviceradar-cli edge hub status` prints it. The route is already inside the
CLI's `edge.manage` scope; no scope is widened.

`edge install leaf` reads the same object before any host change and stops on
the first cause that applies, checked in this order, naming the cause and its
resolver:

1. hub status missing or unreadable: no setting to change; wait and retry,
   and check core's health;
2. enforcement not configured: set `nats.certificateAuthorization.enabled`;
3. enforcement configured but any of the three mounted seeds is absent: core reports `signing keys not provisioned`.
   Hub status displays that reason and leaf install stops, directing the
   issuer Secret owner to provision the missing seeds;
4. enforcement configured but the authorizer otherwise not answering: no setting to
   change; check NATS and core health, then retry, with the readiness reason
   shown;
5. leaf listener not configured: `nats.leafnodes.enabled`;
6. no leaf upstream URL: the install's leaf host setting
   (`hostedRuntime.publicEndpoints.natsLeafHost` today);
7. a chart identity not adopted: the per-subject reason from
   `chart_identities`; there is no Helm setting for this cause.

In every case it changes nothing on the host. It no longer
continues with "hub enforcement stays unconfirmed" for a leaf. Collector
installs keep today's behaviour.

### Decision 6: Turning it on is safe by construction

Admission and reconnection in this rollout apply while at least one broker is serving and core's authorizer is connected.
Core adopts chart identities whether or not enforcement is on. So the order
for an existing install, once its issuer owner has provisioned any externally
managed signing material, is: upgrade to this release with the value off; check
`edge hub status` shows every chart identity adopted; turn the value on. If it
is turned on first anyway, clients are refused only until core's first
reconciliation, and they retry, provided the signing seeds are present and every chart identity
can be adopted automatically. A chart identity that hub status reports as not adopted
stays refused after enforcement is on until its reported reason is resolved,
whatever the reason: for example, rows without a subject blocking new
inventory adoption, a refused or skipped rotation, a revoked subject, or a
failed qualification check. Rows without a subject block only new adoption;
fingerprints already recorded, including by the earlier hand procedure, are
admitted and count as adopted. `edge hub status` shows every not adopted chart
identity with its reason before enforcement is turned on, which is why the
documented order checks hub status first.

Certificate regeneration changes every fingerprint. A certificate that was
already adopted has its successor recorded by
`ServiceRadar.Edge.RuntimeCertificateRotation` from the core migrations hook
before workloads roll onto it, so its client is not refused; the inventory
does not record it. The inventory changes in the same generator run; on the
authorizer's next tick core adopts a qualifying certificate whose subject is
not held. Only such a certificate is refused until then, and its client
retries; the window is bounded by the authorizer's 10 second tick (the
rotation reconciler separately runs every 30 seconds). A replacement whose
predecessor was revoked or superseded is refused by the rotation path, is not
recorded by the inventory because the subject is held, and is
reported with the reason.

## Risks / Trade-offs

- **Availability dependency on core** when enforcement is on. Stated in
  Decision 4. Established sessions are not affected by a core restart;
  connections and reconnections made during it wait.
- **Regeneration does not undo a revocation.** If a chart identity's
  certificate was revoked, its regenerated replacement is not recorded by the
  rotation record, the inventory writes nothing because the subject is held,
  and the subject is reported with the revocation reason. Its client
  stays refused until an operator acts.
- **Residual unrecorded rotation.** When a rotation manifest names an
  unrecorded intermediate predecessor while an older certificate of that
  subject is recorded, neither path records the current certificate. The
  identity is reported unadopted with that reason and an operator records the
  successor through the existing API.
- **Legacy certificate rows without a subject** block all inventory adoption
  until they are recorded again or their component is removed. Expected to be
  empty; task 1.4 checks.
- **The static user `O=ServiceRadar`** (publish allow `>` with deny
  `logs.normalized.>`, subscribe allow `>`) is not a chart identity: no
  chart-generated certificate carries that subject. A broker experiment on the
  chart configuration showed that only a certificate whose whole subject is
  exactly `O=ServiceRadar` maps to it; other unlisted subjects are refused.
  With enforcement on, such a certificate would not be in the inventory and
  would be refused. Task 1.2 checks live deployments for a holder before any
  behaviour changes, then removes the user or documents it.
- **Included broker configuration** is a new shape for the NATS pod. Covered
  by a broker test that boots nats-server from the rendered files, as the
  existing chart permission tests do.

## Migration Plan

1. Ship inventory, automatic adoption, generated keys and readiness with
   enforcement off. This release removes `issuerPublicKey`, `authUserPublicKey`
   and `systemUserPublicKey`. After upgrade the chart ignores public keys
   pasted into these values from a bootstrap record. Enabling enforcement
   uses the mounted seeds without migrating the record.
2. Turn enforcement on in demo; verify every client and a leaf.
3. Control plane change for hosted tenants.
4. Decide the default.

Rollback at any step is setting the value back to false.

## Open Questions

- Decision 4, the default.
- Whether the leaf listener should follow the same value, removing
  `nats.leafnodes.enabled` as a separate setting. Proposed: keep it separate,
  because it adds a Service port and is what the exposure settings key on.
  Either way, `leaf_listener` is rendered from the same condition the chart
  uses to render the listener.
