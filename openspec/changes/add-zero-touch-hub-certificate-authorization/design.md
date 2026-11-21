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

Core mounts public inventory certificates read-only from the runtime certificate
Secret through an explicit item list (`serviceradar.runtimeCertItems`), as it
already does for `runtime-cert-rotation.json`. Only core gains inventory
files. The projection adds no private key, ConfigMap or generator permission.

When the generator job runs (`certs.generator.enabled` is true and the install
is not hosted), it owns the runtime Secret. Core projects the public certificate
of every chart identity regardless of the issuer Secret name. The generator
includes every projected file in its required-files check before preserving an
existing Secret. An older Secret missing even one inventory certificate takes
the existing regeneration path in the pre-upgrade hook. This can reissue all
runtime certificates once on upgrade and write the rotation manifest before
core rolls. A complete, otherwise valid Secret follows the usual preserve path.

For hosted installs and self-managed installs with the generator disabled, the
supplier sets a chart value listing the public inventory certificates its
runtime Secret carries. The list defaults to empty. Kubernetes requires only
the listed inventory files to mount the volume. An explicitly listed but
missing file prevents core from starting. With an empty list core starts,
adopts nothing and hub status reports each chart identity as not adopted
because no inventory certificate is supplied. With a partial list the same
reason applies to each omitted identity. These rules apply with enforcement
on or off.

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
when the predecessor is revoked, superseded or from another issuer. A client presenting the revoked fingerprint is refused. One residual case is not covered by either path: when the rotation
manifest's predecessor is an unrecorded intermediate certificate while an
older certificate of that subject is recorded, the rotation path skips it and
the subject is held, so neither path records the current certificate. The
identity is reported unadopted with that reason, and an operator records the
successor through the existing API. This is fail-closed and visible.

Coverage: a chart identity counts as adopted when the inventory's certificate
for that subject is recorded and not revoked. Otherwise it is reported with
the reason: no inventory certificate supplied, a failed check, legacy rows without a subject, or a held subject
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

The generator owns the signing set only on a non-hosted install with
`certs.generator.enabled` true and the same Secret name resolved by
`serviceradar.runtimeIssuerSecretName` and `serviceradar.runtimeCertsSecretName`.
In the self-managed default this shared runtime Secret also holds the CA key.
In every other configuration the Secret supplier provides the three seeds in
the issuer Secret and both matching fragments in the runtime Secret. This
covers distinct Secret names, hosted installs and self-managed installs
with generation disabled, even when both names identify the same Secret.
Any generator running in those configurations leaves all five entries alone.
Its Role stays unchanged. The chart documents all five keys and their destinations.

On the generator-owned path the signing step runs both before the
existing-certificates early exit and when certificates are generated or
regenerated. Certificate reconciliation controls the successful exit and
writes the rotation manifest when it reissues certificates.

- If all five entries are absent, generate the issuer, auth and system seeds
  and publish them together with both fragments derived from their public keys.
- If all three seeds are present, preserve them and rebuild only missing or
  stale fragments from those seeds. A matching set leaves all five signing entries untouched.
- If any signing entry remains but a seed is missing, fail the job without
  writing. Name each missing seed and direct the operator to restore it or
  deliberately remove all remaining signing entries to provision a new set.

Signing key rotation is outside this change.

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

`serviceradar-cli edge hub status` prints it, marking each uncovered identity as a warning with its
reason for the operator's pre-enforcement review. The route is already inside the
CLI's `edge.manage` scope; no scope is widened.

`edge install leaf` reads the same object before any host change and stops on
the first cause that applies, checked in this order, naming the cause and its
resolver:

1. hub status missing or unreadable: no setting to change; wait and retry,
   and check core's health;
2. enforcement not configured: set `nats.certificateAuthorization.enabled`;
3. enforcement configured but any of the three mounted seeds is absent: core reports `signing keys not provisioned`.
   Hub status displays that reason and leaf install stops, directing the
   signing set owner from Decision 2 to provision the missing seeds;
4. enforcement configured but the authorizer otherwise not answering: no setting to
   change; check NATS and core health, then retry, with the readiness reason
   shown;
5. leaf listener not configured: `nats.leafnodes.enabled`;
6. no leaf upstream URL: the install's leaf host setting
   (`hostedRuntime.publicEndpoints.natsLeafHost` today).

When these checks pass, leaf installation proceeds regardless of chart
identity coverage.

In every case it changes nothing on the host. It no longer
continues with "hub enforcement stays unconfirmed" for a leaf. Collector
installs keep today's behaviour.

### Decision 6: Turning it on is safe by construction

Admission and reconnection in this rollout apply while at least one broker is serving and core's authorizer is connected.
Upgrade with enforcement off. For a generated runtime Secret, the pre-upgrade
hook checks the fixed inventory before core rolls. For a supplied Secret, core
uses only the supplier's inventory list, which may be empty. Review
`edge hub status` and supply any omitted public certificates and list them
before expecting full coverage. Once all chart identities are adopted and the
signing material is provisioned, turn enforcement on.

Coverage compares each inventory certificate with the unrevoked records. An
omitted chart identity produces a warning even if its client was previously
hand-adopted. At connection time the broker uses the presented fingerprint.
With the existing grant and static permission checks satisfied, a recorded,
unrevoked fingerprint is admitted whether or not it appears in the inventory.
A presented certificate with no matching unrevoked record is refused. Legacy
rows without subjects block new inventory adoption only.

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
  and the subject is reported with the revocation reason. A client presenting the unrecorded replacement is refused.
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
   enforcement off. Follow Decision 6 for generated and supplied inventories.
   The hook can rotate runtime certificates before the first core rollout.
   This release removes `issuerPublicKey`, `authUserPublicKey`
   and `systemUserPublicKey`. After upgrade the chart ignores public keys
   pasted into these values from a bootstrap record. Enabling enforcement
   uses the mounted seeds without migrating the record.
2. Turn enforcement on in demo; verify every client and a leaf.
3. Control plane change for hosted tenants.
4. Decide the default.

Turning enforcement off restores static authorization. Inventory projection
still follows Decision 1. If a supplier listed a missing certificate, supply
it or correct the inventory list and roll core. Disabling enforcement does
not undo a certificate reissue or the existing rotation records.

## Open Questions

- Decision 4, the default.
- Whether the leaf listener should follow the same value, removing
  `nats.leafnodes.enabled` as a separate setting. Proposed: keep it separate,
  because it adds a Service port and is what the exposure settings key on.
  Either way, `leaf_listener` is rendered from the same condition the chart
  uses to render the listener.
