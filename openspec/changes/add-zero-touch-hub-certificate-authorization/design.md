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

The generator writes a ConfigMap, `serviceradar-nats-infrastructure-certs`,
holding one PEM certificate per chart identity. It contains no private key and
not the CA key. Core mounts it read-only, like the static users ConfigMap. It
is a separate ConfigMap and not another key in the runtime Secret, from which
core mounts only its own items. The precedent for the generator publishing
public certificates is `runtime-cert-rotation.json`, a JSON document inside
the runtime Secret that holds public certificates and the fingerprints they
replaced, with no key material.

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

Why this adds no trust: a certificate that chains to the root and carries a
chart subject is already accepted by the broker today through
`verify_and_map`. Writing the ConfigMap needs the same Kubernetes rights as
changing the chart's static users. Revocation still wins.

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
  Rejected: it needs Kubernetes access to the Secret holding the CA keys, it
  is not available to a hosted tenant, and it does not survive regeneration.
- Give core RBAC to read the Secret. Rejected: core would hold every
  component's private key.
- Admit chart subjects by subject alone, with no adoption record. Rejected:
  the existing design keeps a per-fingerprint record so one certificate can be
  revoked and used certificates can be listed; this keeps that.

### Decision 2: The chart owns the signing keys

The generator creates the issuer, auth and system nkeys once and never
replaces existing ones. Seeds go into a Secret, `serviceradar-nats-callout`,
mounted only into core. The public keys go into a broker configuration
fragment in a ConfigMap, which the NATS pod mounts and the server
configuration includes.

Core reads the seeds from the mounted files when they are present. The
database record and `POST /nats/certificate-authorization/bootstrap` remain
for installs with no chart; when both exist and disagree, core reports
`signing_key_conflict` and does not answer authorization requests.

Why not keep the keys in the database and copy public keys into values: that
copy is the hand step being removed, and Helm cannot read the database at
render time.

Hosted tenants: the control plane creates the Secret and the fragment, as it
already creates the certificate Secret. That is a change in
`serviceradar-control`, tracked there.

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
3. enforcement configured but the authorizer not answering: no setting to
   change; wait and retry, and check core's health, with the readiness reason
   shown;
4. leaf listener not configured: `nats.leafnodes.enabled`;
5. no leaf upstream URL: the install's leaf host setting
   (`hostedRuntime.publicEndpoints.natsLeafHost` today);
6. a chart identity not adopted: the per-subject reason from
   `chart_identities`; there is no Helm setting for this cause.

In every case it changes nothing on the host. It no longer
continues with "hub enforcement stays unconfirmed" for a leaf. Collector
installs keep today's behaviour.

### Decision 6: Turning it on is safe by construction

Core adopts chart identities whether or not enforcement is on. So the order
for an existing install is: upgrade to this release with the value off; check
`edge hub status` shows every chart identity adopted; turn the value on. If it
is turned on first anyway, clients are refused only until core's first
reconciliation, and they retry.

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
   enforcement off. Nothing changes for running installs.
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
