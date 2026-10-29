# ServiceRadar Cloud resource contract

## Ownership and observed reuse points

The SaaS control plane is the separate
[serviceradar-control repository](https://github.com/carverauto/serviceradar-control).
All new issues and PRs use GitHub. Each provisioned ServiceRadar runtime remains
single-deployment; control-plane account/environment identity is not a new tenant
column or routing mode in the runtime.

Inspection baseline: control-plane commit
`9e5a47aefa6529092f7cf2102ad59e6754303fee` (local checkout, not claimed latest).
Relevant existing code:

| Component under lib/serviceradar_control/cloud/ | Existing responsibility | VMS extension |
| --- | --- | --- |
| provisioning_run/steps/setup_backup_storage.ex | Resumable backup bucket/key provisioning and Secret materialization | Separate media-purpose provisioning step; reuse orchestration patterns, never backup buckets |
| provider/akamai/storage.ex | Object bucket allocation, bucket-scoped keys, inventory and deletion | Read/write role separation, bucket security reconciliation and preservation-aware deletion |
| object_storage_credential_custody.ex and its open_bao backend | Custody references; secret bytes excluded from chart values/metadata | Independent recorder, reader and lifecycle credential generations |
| tenant_runtime_values.ex and tenant_launch_preflight.ex | Runtime values and launch gates | Versioned VMS configuration and capability probes |
| tenant_add_on_quota.ex and self_service_add_ons/quota_gate.ex | Add-on admission | Recording, storage, playback and GPU budgets |
| provisioning_run/steps/deprovision_resources.ex | Environment cleanup | Drain/hold/export decisions before media deletion |

The current Akamai key creation requests bucket `read_write`; that is not proof
of the narrower recorder/playback/delete roles needed here. Existing generic
bucket deletion purges objects, so VMS resources must be classified and excluded
until their preservation workflow authorizes deletion.

Akamai's documented limited keys still allow bucket creation/listing, and their
`read_write` role includes deletion and lifecycle/versioning changes. For this
provider, keep bucket keys in the storage service and give recorders narrowly
authorized object-upload operations. A limited key alone cannot establish the
required no-provisioning/no-retention-authority recorder boundary. Direct worker
credentials require separate evidence that the endpoint enforces the narrower
actions. See [Akamai access-key permissions](https://techdocs.akamai.com/cloud-computing/docs/manage-access-keys).

## Next bounded Cloud checkpoint

[Cloud #188](https://github.com/carverauto/serviceradar-control/pull/188) is merged.
The next independent Cloud scope exposes read-only reservation inventory and preservation status through
the existing operator environment console. This is a bounded part of the
approved Cloud design's resource inventory and lifecycle visibility; it does not
complete provisioning or the ownership gate below.

- Reuse `TenantMediaAllocationIntent` and `TenantMediaReservations`. Preserve
  immutable environment, operation, purpose and generation identity, operator
  attribution and the sticky preservation fence.
- Extend `OperatorEnvironmentConsole.get_environment/2`, its detail projection
  and `OperatorEnvironmentLive` at `/operator/environments/:id`. Present a bounded
  list of requested provider/region and purpose with explicit continuation when
  more reservations exist. Never imply that a truncated list is complete.
- Label these as reservations with ownership not established. They are not
  observed provider resources, allocated buckets or readiness evidence. No
  provider request is needed to render them.
- Grant the existing operator-console owner narrowly scoped read authority.
  Keep reservation mutation authority separate and retain environment scoping.
  No create, adopt, clear-preservation, delete or enable-recording action belongs
  in this checkpoint.
- Do not expose credentials, private credential references or opaque provider
  response bodies. Existing infrastructure credential custody remains the owner
  of secret material.

Behavioral acceptance must cover authorized and unauthorized readers, isolation
between environment details, empty and bounded multi-page inventory, immutable
intent display and visible preservation when generic cleanup is refused.
Reading or paging must not call the provider, create reservations, change
preservation or promote readiness. Tests must execute the domain projection and
LiveView behavior using independently invented records, with committed fixture
rows cleaned up.

This visibility work does not require an adoption decision. Ownership promotion
still requires an accepted operation-bound proof contract or a separately
specified adoption workflow, and adopting any particular resource remains an
explicit operator action. A matching name, successful list or successful create
response cannot supply that authority.

## C1. Provisioning and private storage

For S3-backed recording, the control plane creates or explicitly adopts
purpose-scoped recording, evidence and derivative storage for one environment.
Keep it separate from CNPG backups and StarRocks storage. Store provider IDs,
region/endpoint, ownership, purpose, policy revision, lifecycle/lock mode, quota
and credential references; never raw secrets.

[Recording-plane Cloud scope](../add-scalable-camera-recording-plane/cloud-scope.md)
owns mode selection and customer-operated pool provisioning. The object-storage
steps and qualification gates below apply when S3 is selected.

Use persisted idempotent provisioning steps: allocate, persist IDs, configure
security, create/custody keys, materialize runtime references, probe, mark ready.
Retries after provider success or lost responses reconcile ownership before
adoption. Rollback preserves data and reports incomplete allocations as managed
cleanup work. A user naming an existing bucket is not authorization to adopt it.

### Allocation ownership gate

The [Akamai create-bucket API](https://techdocs.akamai.com/linode-api/reference/post-object-storage-bucket)
returns HTTP 200 for an existing same-account bucket as well as a newly created
one. Its documented request has no conditional-create or operation-token field.
Consequently a successful response alone does not establish that this allocation
operation created the bucket. A preceding GET races with other creators;
random names and creation timestamps do not resolve operation ownership.
S3 compatibility is not an alternative proof: [AWS CreateBucket](https://docs.aws.amazon.com/AmazonS3/latest/API/API_CreateBucket.html)
also documents an existing-owner success exception for its legacy region.

Before enabling an allocator, establish provider-supported atomic create-new or
durable operation-bound identity, or separately specify and authorize explicit
adoption with the same security checks. Otherwise preserve unresolved inventory
and deny binding readiness and cleanup. Do not add a worker whose only possible
outcome is an unsupported capability. This gate does not block product transport
tests against synthetic endpoints or a separately validated operator-managed
destination.

The future allocator's synthetic acceptance must make new and pre-existing
buckets return identical documented success responses and verify that neither
becomes an owned allocation without additional proof. Include the GET/create
race, lost response, malformed success and persistence failure; retain the
original operation identity and do not issue another create while unresolved.
Pair rejections with a positive fixture for the selected proof contract. These
tests validate our state handling, not Akamai's actual semantics; live acceptance
and provider confirmation remain separate prerequisites.

### Security readiness

Security readiness requires observed negative and positive probes:

- Anonymous list/read/write denied; no public ACL, website hosting or wildcard
  allow. TLS required and encryption-at-rest support verified for the chosen
  provider/endpoint and deployment policy.
- Recorder can write only its media purpose; playback cannot upload/delete;
  deletion credentials are unavailable to recorder and GPU workers. If provider
  policy cannot express a role, use a mediating service and fail closed on
  unsupported direct access.
- Deny access across environments and reject arbitrary endpoints. Protect against
  SSRF and redirect-based escape. Browser CORS permits only configured origins,
  GET/HEAD and needed range headers; CORS is not authorization.
- Reconcile policies without destroying provider-managed limited-key statements.
  Detect drift and stop unsafe admission; never silently make a bucket public.
- Rotate credentials in overlapping generations: install, probe, switch, observe
  readers/writers, revoke old generation; do not strand multipart recovery.
- Evidence storage is provisioned with its explicit retention/lock capability.
  Native Object Lock is a creation-time/provider gate; no retroactive assumption.

Service-to-service S3/NATS/worker credentials use existing infrastructure custody
and Kubernetes Secret references. Monitored camera credentials stay in the
runtime unified credential inventory, not SaaS provisioning records.

## C2. Versioned runtime configuration and admission

A versioned configuration document contains mode-selected purpose-specific endpoint/bucket
references, secret references and generations, archive format support, retention
policy, local spool/cache resource profile, enabled media capabilities, GPU
placement/queue policy, and budgets. The control plane sends desired revision;
runtime reports applied revision and measured capability/readiness. Incompatible
revisions fail closed without disrupting already admitted live viewers.

The product-owned [qualification report format](qualification-report.md) now
defines bounded observation metadata and canonical report identity. It is only
part of this contract: parsing does not authenticate the producer, establish
freshness or install storage authority. The [private receipt
endpoint](qualification-receipts.md) persists ordered submissions/withdrawals
through the existing control listener, but reports no applied revision. Its
media routes now require [a separate deployment-bound credential](media-authentication.md)
and exact installation headers; the account/password-reset token is rejected.
Installation acknowledgment identifies the responding process only, and a receipt
is not evidence of storage credential installation. The merged
[Cloud readiness proposal](https://github.com/carverauto/serviceradar-control/pull/185)
still requires completion of the desired/applied handshake and lifecycle
gates before hosted enablement.

The product's [archive-publication checkpoint](archive-publication.md) adds a
fixed installed-purpose map for init, media and manifest operations in one
isolated storage workload. Cloud orchestration must retain the shared binding,
local storage lifetime and credential identity while installing each purpose's
independent desired revision and original challenge window. A workload restart
replaces its boot identity for every purpose; it cannot renew or resend an old
prepared operation. Installation must budget the bounded sequential challenges
and keep the complete configuration within 32 KiB. The existing C1/C2 work must
validate this handshake alongside provider ownership, qualification, egress and
spool provisioning before hosted enablement. Per-block archive publication does
not satisfy that deployment readiness contract.

Budgets cover admitted cameras and aggregate bitrate, spool bytes/time, cache
bytes, pending archive age, archive/evidence/export storage, read/egress
concurrency, GPU jobs/streams/memory and inference rate. A full budget rejects or
degrades optional work explicitly; it cannot evict unarchived media or starve
telemetry/control. Define metering units and deduplication before billing;
provider inventory is reconciled against application usage.

Hosted enablement is separate from testing with operator-created resources.
Community installations can supply the same validated storage/configuration
contract without the SaaS control plane. Unsupported optional features stay off.

## C3. GPU placement and environment isolation

First delivery uses dedicated worker identity and queue permissions per runtime
deployment. A physical GPU node pool may host multiple workloads only with an
explicit scheduling and security policy; do not expose one broad worker key or
join unrelated runtime BEAM clusters. Shared cross-environment GPU service design
is a future hardening/cost decision, not implied by a Kubernetes node selector.

Provision/select capable node pools using labels, taints/tolerations, device-plugin
resources and availability checks. Validate CPU architecture, CUDA/driver/runtime,
model backend, memory, decode/encode support and container image digest on the
actual hardware. GPU presence alone proves none of those. No hostnames from a
live cluster are baked into charts.

Capability reports distinguish physical devices, MIG partitions and time-sliced
shares. A scheduler resource count is not a measurement of dedicated compute or
memory. NVIDIA time-slicing provides no memory or fault isolation between its
replicas, so shared units cannot satisfy a contract requiring those properties.
Admission and metering must name the sharing class and verified model capacity;
requesting multiple shared units does not promise proportional compute. Validate
the device plugin, container toolkit and an actual worker workload, not node
readiness alone. See [NVIDIA GPU sharing](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html).

The existing [multi-pool commercial work #112](https://github.com/carverauto/serviceradar-control/issues/112)
is a dependency for pricing/authorizing separate hosted GPU pools, not a reason
to duplicate provider pool provisioning. Coordinate TURN/network usage with
[control-plane #156](https://github.com/carverauto/serviceradar-control/issues/156).
Ephemeral viewer jobs and durable analysis/export jobs have different capacity
classes so a bulk transcript queue cannot exhaust interactive playback.

## C4. Suspend, recover and terminate

Suspend first stops new recording and optional GPU admission, then seals/drains
pending work according to policy. Retained footage, evidence and billing/storage
state remain discoverable. Resumption reconciles ownership and credentials;
suspension is not deletion.

Termination requires a recorded disposition for ordinary footage, evidence holds,
active exports, replicas/versions, manifests, derived artifacts and search
projections. Preservation obligations can block deletion. The generic provider
purge must not bypass that decision. Verify object/version absence, multipart
cleanup, key revocation and provider inventory before declaring completion.
Failures remain resumable and visible; do not delete the only inventory first.

Recovery verifies CNPG index/hold restoration against immutable archive manifests.
Index recovery does not imply recovery of provisional local bytes. Reconcile
storage location and data residency when restoring into another environment.

## Validation environment and handoff

Use the operator-designated existing Kubernetes test namespace and RTSP source
for a staged live acceptance pass after synthetic tests. The current session
authorizes `linode-cli` creation of dedicated test buckets for that future work.
Record concrete cluster, namespace, camera, GPU nodes, bucket IDs and credentials
only in private operational state; never commit them as fixtures/examples.

Test bucket creation starts with explicit region, purpose, private policy and a
cleanup owner. Confirm negative access probes before sending footage. Cloud
provider administration stays operator-side; production provisioning uses the
provider adapter. Testing must prove teardown of test-owned objects/keys and
must preserve unrelated resources.

The cloud work is divided into three separately reviewable issues:

- [C1 provisioning/security: #182](https://github.com/carverauto/serviceradar-control/issues/182).
- [C2/C4 quotas, metering and lifecycle: #183](https://github.com/carverauto/serviceradar-control/issues/183).
- [C3 GPU placement and isolation: #184](https://github.com/carverauto/serviceradar-control/issues/184).

Each issue requires a
control-plane OpenSpec and review before implementation. This document is the
cross-repository API contract, not a control-plane code change.

## Primary references

- [Akamai bucket policies](https://techdocs.akamai.com/cloud-computing/docs/define-access-and-permissions-using-bucket-policies):
  reconcile limited-key policies rather than replacing them blindly.
- [Akamai Object Lock](https://techdocs.akamai.com/cloud-computing/docs/protect-data-with-object-lock):
  verify creation-time configuration and version-aware behavior.
- [Akamai limits](https://techdocs.akamai.com/cloud-computing/docs/object-storage-product-limits):
  account/endpoint quotas and multipart limits are capability inputs.
