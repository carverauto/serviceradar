## Surface before this change

The following is the pre-implementation gap analysis. For the implemented subset,
see the [provisioning API contract](../../../docs/docs/ansible-provisioning-api.md)
and [Terraform reference](../../../docs/docs/terraform-provider.md).

Source inspection before implementation found these capabilities:

| Area | Existing public API | Missing contract |
| --- | --- | --- |
| Credential secrets | List, create, read, update, rotate | Guarded deletion, concurrency and retry semantics |
| Credential rules | List, create, read, update, enable, disable | Guarded deletion and declarative reconciliation |
| AWX controllers | List, create, read, update, enable, disable | Guarded deletion, readiness, scoped reconciliation |
| Git playbook repositories | UI and Ash resource | Public lifecycle and sync/status API |
| Inventory and membership | Sync workers and review resources | Bounded discovery and evidence-based review API |
| Template bindings | Immutable review and live preflight services | Public review/version/revoke API |
| Deployment | Canonical prepare/launch and operation services | Public prepare/launch/status/cancel API |
| Upstream AWX configuration | Read commands and job execution | Typed provisioning commands and ownership reconciliation |
| Terraform | No first-party implementation found | Provider resources, import, drift and acceptance tests |

Relevant source anchors are
`elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`,
`controllers/api/ansible_controller_controller.ex` under that web namespace,
`plugs/api_auth.ex`, `plugs/confine_narrow_scope.ex`,
`elixir/serviceradar_core/lib/serviceradar/automation/ansible/`, and
`go/cmd/wasm-plugins/awx/`.

User-bound API keys and OAuth client credentials already resolve to an account
and its role profile. Reuse that account identity. Legacy static keys without
an accountable user cannot provision. Before this change, controller endpoints
required RBAC but did not consistently intersect coarse token scopes with mutation authority; closing that gap is part
of the configuration API contract.

## Public Boundary

Use explicit JSON endpoints under the existing authenticated `/api/admin`
configuration boundary. Publish request, response, authorization, pagination,
error, and asynchronous status schemas in OpenAPI. Resource UUIDs are stable;
upstream AWX numeric identifiers remain controller-scoped attributes.

| Resource family | Lifecycle |
| --- | --- |
| `network-credential-secrets`, `network-credential-rules` | Complete existing routes; preserve unified storage and usage guards |
| `ansible-controllers` | Complete existing routes and expose health/readiness |
| `ansible-repositories` | CRUD, explicit sync request, sync status |
| `ansible-inventories`, `ansible-memberships` | Bounded read/sync and explicit evidence-backed review |
| `ansible-template-bindings` | Read, prepare review, approve immutable version, revoke |
| `ansible-awx-resources` | Typed project/inventory/source/environment/template/role configuration |
| `ansible-provisioning-operations` | Durable reconciliation status and cancellation where safe |
| `ansible-operations` | Explicit prepare/launch, exact targets, status/results, cancel |

The final endpoint names should follow existing controller conventions during
implementation. These are typed resource APIs, not an arbitrary AWX URL,
request-body, verb, SQL, or RPC proxy.

## Authorization and Credential Custody

- Require current account RBAC and the token's corresponding read/write/admin
  capability. Narrow OAuth scopes remain confined. Test the real authentication
  pipeline as well as controller policy decisions.
- Reuse existing Ansible permissions for current resources. Add a distinct
  `ansible.controllers.provision` permission for upstream AWX configuration,
  administrator-only by default. Provisioning cannot imply run launch,
  delegation, binding approval, credential rotation, or target-hold clearance.
- Preserve the real initiating account and fixed delegation ceiling in queued
  operations. Revocation or role contraction blocks undispatched mutations.
  A worker SystemActor is transport authority, never replacement authorization.
- If upstream provisioning requires a separate controller credential reference,
  add it as an explicitly approved typed consumer: restrictive foreign key,
  complete credential usage inventory, guarded deletion, and navigable usage.
  Store material only in `platform.network_credential_secrets`.
- Use a separate broker purpose and exact host/path/method/body policy for
  provisioning. Do not widen inventory-sync or job-execution grants. Credentials
  remain outside Wasm memory and never enter public operation bodies.
- Initial credential creation and rotation accept write-only material. Resource
  reads return references and non-secret metadata. No secret-value digest is
  exposed as drift metadata.

## Reconciliation and Failure Semantics

Every create accepts a scoped idempotency key. Repeating an identical request
returns the same resource/operation; reusing a key with a different request
fails with a conflict. Updates and deletes require an expected version or ETag.
Stale writers fail rather than overwriting an operator's newer configuration.

Maintain durable ownership records mapping a ServiceRadar UUID to an exact
controller, upstream type, upstream ID, and last observed configuration version.
Import/adoption names an explicit upstream ID and checks authorization and live
identity. A matching display name is not proof of ownership. Do not delete or
rewrite unrelated AWX resources, external credentials, or role grants.

AWX writes are asynchronous, typed agent commands with bounded bodies and
secret-free projections. After a timeout, reconcile the exact upstream identity
and operation marker before retrying. An ambiguous create remains visibly
unresolved; do not repeat a potentially successful POST blindly. Partial
bootstrap reports per-resource outcomes and is resumable. Cancellation cannot
claim an already accepted external mutation was undone.

Deletion is explicit and reference-aware. An active template binding, operation,
credential consumer, or another managed dependent prevents unsafe deletion.
Disabling a resource is a distinct action, not a disguised successful delete.

## AWX Observation Ordering and Membership Authority

An AWX observation generation orders complete or partial controller snapshots.
A membership's `source_generation` identifies the observation that last changed
its execution authority. Unchanged observations refresh last-seen data while
preserving that authority generation, so polling does not invalidate active jobs.
Changes to the exact target tuple, canonical device, address, enabled/current
state, source fingerprint, or linkage disposition/evidence still change authority.

A separate durable per-controller watermark orders observations, including
partial and complete-empty snapshots. Controller locks are acquired in stable
order before device writes. AWX device batches run on the transaction owner;
device writes, membership reconciliation, and watermark advancement commit
together. Stale or conflicting observations and failed reconciliation roll back.
Device-state events, cache invalidation, and membership notifications are emitted
only after the outer transaction commits.

## Terraform

Implement the provider in Go with HashiCorp's recommended Plugin Framework and
declare its dependencies and build/test targets in Bazel. Terraform talks only
to ServiceRadar. The service provisions upstream AWX objects through its broker;
the customer does not need a second hidden set of direct AWX mutations.

Expose resources and data sources incrementally using the same stable IDs as
the API. Support import of existing ServiceRadar resources and separately
authorized adoption of upstream objects. Read canonical server state so a
second unchanged apply has no changes and an out-of-band edit appears as drift.
Wait for asynchronous configuration operations with bounded polling/timeouts.

Prefer credential IDs. Where bootstrap must submit new material, use Terraform
write-only arguments with an explicit non-secret rotation version and ephemeral
inputs. Set the minimum Terraform version required by those features. Marking
an ordinary argument sensitive is insufficient to keep it out of state.
HashiCorp documents the framework contract at
https://developer.hashicorp.com/terraform/plugin/framework/resources/write-only-arguments.

Plan/refresh must be read-only. A normal configuration apply cannot launch a
playbook, approve a changing membership, or approve a new binding snapshot.
Expose pending review IDs and readiness explanations as outputs. Explicit
approval uses the same evidence and permissions as the UI. Deployment is a
separate API operation using a fresh prepare result and idempotency key.

## Validation

Use invented controllers, hosts, identifiers, addresses, and artifacts throughout
tests and examples. Acceptance fixtures must exercise bootstrap, repeated apply,
import, drift, refresh, failed/partial asynchronous reconciliation, retry after
ambiguous responses, deletion guards, scope contraction, secret redaction, and
plan/state inspection. API launch tests must prove that stale review, wrong
controller, quarantined membership, extra targets, or revoked authority prevents
any AWX mutation.

Live verification is an operator action against an explicitly selected
environment. Its captured values and output never become repository fixtures.

## Boundaries

This change does not install the initial ServiceRadar or AWX server, bypass
first-admin authentication, create arbitrary upstream administrator accounts,
or relax the callback/SSH enrollment readiness contract. Terraform can manage
the infrastructure running those servers through their normal infrastructure
providers before configuring ServiceRadar through this provider.
