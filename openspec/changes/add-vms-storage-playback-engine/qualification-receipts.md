# Private qualification receipts

This pass connects the [report format](qualification-report.md) to durable
receipt storage through the existing private control-plane listener. It is a
qualification sub-contract. It does not implement the full desired runtime
configuration, applied configuration, evidence verification or storage authority.

## Wire contract

`PUT /v1/archive-bindings/:binding_id/qualification` submits one complete JSON
document. The binding must already exist; the canonical lowercase path UUID
selects that retained destination. Every key below is required and unknown keys
are rejected.

| Field | Version 1 value |
| --- | --- |
| `schema_version` | Integer `1` |
| `revision` | Positive signed-bigint revision, increasing for each binding |
| `state` | `submitted` or `withdrawn` |
| `report` | Version 1 qualification report for `submitted`; JSON `null` for `withdrawn` |

The submitted report's binding UUID and computed destination digest must match
the retained binding. Its credential references remain metadata. A report may
contain failed, unavailable or expired observations because receipt is not
readiness evaluation.

The listener requires [deployment-scoped media authentication](media-authentication.md)
before reading the body. The dedicated bearer token and exact installed
deployment/generation headers are mandatory; the account/password-reset token
is rejected. Standard `Authorization` remains reserved for Kubernetes API
authentication. JSON bodies require `application/json`, are capped at 16 KiB,
and preserve integers without float coercion. Duplicate keys, including escaped
spellings of the same key at any object depth, are rejected before conversion to
maps. Arrays are outside this contract. Responses use `Cache-Control: no-store`.
The route is absent from the public router, Service ports and Gateway routes.

The installed credential authenticates requests to this deployment and generation.
Receipt rows do not preserve historical caller identity, and old rows can predate
this authentication boundary. A payload cannot supply missing authority. A full
desired/applied installation and a fresh correlated exchange remain prerequisites
for storage enablement; retained receipts cannot be promoted to that authority
just because this listener accepted them.

## Revision and persistence rules

`Camera.ArchiveQualifications` serializes submission under the retained binding
lock. `ArchiveQualificationReceipt` keeps one current row per binding, separate
from the immutable destination. Its restrictive foreign key retains the binding.

- A higher revision replaces the current receipt.
- The current revision with the same content returns the original receipt and
  timestamp. A changed document at that revision returns HTTP 409.
- Every older revision returns HTTP 409, including a delayed submission following
  a newer withdrawal. Withdrawal retains the revision high-water mark and clears
  the report; it does not delete the destination or revoke provider credentials.
- Submission cannot run inside an ambient database transaction. A successful
  return follows its own commit, so it cannot acknowledge a later outer rollback.

The receipt digest is lowercase SHA-256 over compact JSON encoding of the array
`["archive-qualification-v1", binding_id, revision, state, report_sha256]`.
`report_sha256` is the canonical report digest for a submission and JSON `null`
for a withdrawal. This binds every accepted envelope field without inventing a
second report canonicalization. It is not the full desired-configuration digest
specified by the Cloud provisioning proposal.

The current row is bounded state, not an audit history or evidence repository.
The producer retains the evidence named by `result_ref`. The database receipt
time records arrival only; it is not a freshness clock or expiry extension.

## Status and remaining work

`GET` on the same private path reloads the receipt. A successful `PUT` or a `GET`
with a current receipt returns HTTP 200 with `status: recorded`, binding UUID,
revision, state, receipt/report digests and `received_at`. Both also return
`applied_revision: null`, `readiness: unavailable` and
`reason: qualification_receipt_only`. Reports and credential references are not
echoed. A known binding without a receipt returns `status: not_submitted` with
the same unapplied/unavailable state; an unknown binding returns HTTP 404.

Malformed input or mismatched binding returns HTTP 400, oversized input 413,
unsupported media type 415, and storage failure 503. Error responses contain
bounded status names rather than database errors or request content.

All nineteen observations being `passed` still leaves `ArchiveBinding`
unqualified. No dispatch, credential lookup, provider request, recording
activation or local-media reclamation follows receipt. Bounded init and media
installation are owned by [init authority](init-authority.md) and
[media upload](media-upload.md); a receipt still does not install either.
Hosted configuration, protection-mode evidence and credential installation
remain separate from this receipt.
