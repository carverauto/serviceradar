# Ansible provisioning API

The ServiceRadar JSON API manages reusable credentials, credential rules,
controller registrations, and Git playbook repositories. It also exposes the
canonical operation launch flow and human review of exact AWX memberships and
template bindings. All paths below start with `/api/admin`.

This foundation does **not** create upstream AWX organizations, projects,
inventories, inventory sources, credentials, or job templates. Those objects
must already exist. Binding review currently supports **non-callback bindings
only**. The [Terraform provider](./terraform-provider.md) currently covers four
families: credential secrets, credential rules, controllers, and repositories.
It does not approve authority or launch operations.

## Authentication and permissions

Use a user-bound API key in `X-API-Key`, or an access/API bearer token in
`Authorization: Bearer ...`. The user must be active. Token capabilities and
account RBAC both apply: `read` permits reads, while `write` or `admin` permits
mutations subject to RBAC. Narrow scopes remain restricted to their allowed
routes; an empty API bearer scope grants no configuration access.

| Action | Required RBAC permission |
| --- | --- |
| Read or manage credentials and rules | `settings.credentials.manage` |
| Read or manage controllers | `ansible.controllers.manage` |
| Read repositories, sync status, or template bindings | `ansible.catalog.view` |
| Manage repositories or request synchronization | `ansible.repositories.manage` |
| Read operations or inventory memberships | `ansible.runs.view` |
| Prepare or launch an operation | `ansible.runs.launch` |
| Approve memberships; prepare, create, or revoke bindings | `ansible.controllers.manage` |

Operation preparation/launch and membership/binding mutations currently require
a human principal. Requests associated with an OAuth client are rejected for
these actions. Configuration CRUD can use an appropriately scoped OAuth client.

## Configuration lifecycle

Each collection supports `GET` and `POST`; its `/{id}` path supports `GET`,
`PATCH`, and guarded `DELETE`. IDs are exact ServiceRadar UUIDs.

| Collection | Additional actions and constraints |
| --- | --- |
| `/network-credential-secrets` | `POST /{id}/rotate` accepts a `values` object. Secret material is write-only and stored through the unified encrypted credential model. Deletion requires no remaining usage. |
| `/network-credential-rules` | `POST /{id}/enable` and `/disable`. Deletion requires a disabled rule, no unexpired issued/active broker grants, and no remaining consumer references. Historical grants remain retained. |
| `/ansible-controllers` | `POST /{id}/enable` and `/disable`; `GET /{id}/readiness`. Deletion requires a disabled, unused controller, including no retained execution references. Dependency checks also require catalog read authority. |
| `/ansible-repositories` | `POST /{id}/sync` returns `202` with `scheduled` or `already_scheduled`; `GET /{id}/sync` reports observed status. Catalog entries prevent deletion. |

Controller readiness reports observed health and configured credential
references. It makes no upstream request and does not establish launch
readiness. Repository creation/updates may schedule catalog synchronization;
registration and synchronization do not approve or execute playbooks.

Repositories accept `name`, `description`, `git_url`, `git_ref`,
`sync_interval_seconds`, and nullable `credential_secret_id`. Only public HTTPS
Git URLs without embedded credentials, query parameters, or fragments are
supported. Non-null repository credentials are currently rejected. The minimum
sync interval is 60 seconds. List pagination returns `items` and `next_cursor`;
send that cursor as `after`, with an optional `limit` from 1 to 500.

This controller registration example is entirely synthetic. Its agent and
credential UUIDs must refer to existing ServiceRadar records in a real request:

```http
POST /api/admin/ansible-controllers
Content-Type: application/json
Idempotency-Key: 11111111-2222-4333-8444-555555555555

{
  "name": "Example AWX",
  "base_url": "https://awx.example.com",
  "agent_id": "example-edge-agent",
  "sync_credential_secret_id": "22222222-3333-4444-8555-666666666666",
  "execution_credential_secret_id": "33333333-4444-4555-8666-777777777777",
  "enabled": true
}
```

## Concurrency, retries, and status codes

Singular configuration resource reads and successful body-returning mutations return an
`ETag`. Send it verbatim in `If-Match` to prevent concurrent overwrites. The
header is required for repository updates and all configuration deletions. It
is optional for existing credential/controller updates, secret rotation, and
enable/disable actions. Successful deletion returns `204` without a body.

Repository creation requires a UUID `Idempotency-Key`. The key is optional on
credential/rule/controller creation and secret rotation. Retain the same key,
request body, account, OAuth client, and endpoint after a timeout. A matching
replay returns the original resource's current representation without repeating
the mutation. Configuration idempotency headers do not apply to operation or
review endpoints.

| Status | Meaning |
| --- | --- |
| `400` | Invalid request or malformed/missing required idempotency key or malformed `If-Match`. |
| `401` / `403` | Authentication, active-user, token-scope, or RBAC requirement failed. |
| `404` | Requested resource was not found. |
| `409` | Stale configuration version, guarded deletion, conflicting idempotent request, or request still in progress. Refresh and review before changing the request. |
| `410` | The resource associated with an idempotent replay was deleted. |
| `422` | Resource validation or canonical operation/review contract rejected the request. |
| `428` | Required `If-Match` was omitted. |
| `503` | Idempotency receipt storage is unavailable; retain the key and request for retry. |

## Exact membership and binding review

List current memberships with
`GET /ansible-memberships?controller_id={uuid}&inventory_id={awx-id}`. Review the
source tuple and displayed link evidence. To approve one proposal, send
`POST /ansible-memberships/{id}/approve` with exactly `controller_id`,
`inventory_id`, `awx_host_id`, `canonical_device_uid`, `source_generation`,
`source_fingerprint`, and `link_evidence_digest` from that observation.
`source_generation` is returned as a decimal string; preserve it as a string
to avoid losing signed 64-bit precision. Use the canonical positive decimal form
without signs, whitespace, or leading zeros, up to `9223372036854775807`.
Approval compares the exact current
proposal and freshly checks the reviewer's authority. A changed proposal
requires another review.

The membership's generation identifies the source observation that last changed
its execution authority. An unchanged sync refreshes its last-seen time without
invalidating an approved membership or an active operation. ServiceRadar tracks
the latest accepted observation separately to reject older or conflicting
snapshots before they can overwrite device or membership state. Changes to the
target identity, address, enabled/current state, or linkage evidence still
invalidate the previous authority.

Template binding review has two phases:

1. `POST /ansible-template-bindings/prepare` with `controller_id`, `template_id`,
   `project_id`, `inventory_id`, `credential_ids`, `execution_environment_id`,
   `membership_ids`, `machine_credential_id`, `content_sha256`, and
   `review_ticket`. Optional fields are `input_schema`, `input_classifications`,
   and `approval_ttl_seconds`. Memberships must be approved, current, enabled,
   unique, and belong to that controller/inventory.
2. Inspect the returned `review` and `review_digest`. Submit the same request to
   `POST /ansible-template-bindings`, adding `expected_review_digest`. The
   service repeats brokered AWX reads and requires the review digest to match
   before creating the approved version. It does not accept a caller-supplied
   replacement snapshot.

List versions with
`GET /ansible-template-bindings?controller_id={uuid}&job_template_id={awx-id}`.
Revoke a version with `POST /ansible-template-bindings/{id}/revoke` and an empty
JSON object. These actions review existing AWX configuration; they do not
provision upstream objects.

## Prepare, launch, and observe operations

`POST /ansible-operations/prepare` accepts only `device_uids` and `playbook_id`.
It resolves the approved membership/binding and returns allowed modes and
input definitions. Preparation does not launch a job.

Use the same selection with reviewed inputs in `POST /ansible-operations`:

```json
{
  "device_uids": ["sr:44444444-5555-4666-8777-888888888888"],
  "playbook_id": "55555555-6666-4777-8888-999999999999",
  "inputs": {},
  "mode": "check"
}
```

These identifiers are synthetic. `mode` is `run` or `check`, subject to the
reviewed binding. Launch repeats canonical authorization and live preflight;
the API does not accept raw AWX limits, templates, credentials, or arbitrary
extra variables as launch authority. A `202` response contains the persisted
operation bundle, not a successful job result. Observe it through
`GET /ansible-operations/{id}` or list operations with `GET /ansible-operations`
and an optional `state` filter.

`POST /ansible-operations/{id}/cancel` currently returns **501** with
`cancellation_not_implemented` after authorization (`ansible.runs.cancel`);
it does not cancel an AWX job. This page describes the implemented API
contract, not verification against a live deployment or database.
