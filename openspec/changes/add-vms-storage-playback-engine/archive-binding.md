# Immutable recording archive destination

`Camera.ArchiveBinding.register/2` retains one product-owned provisioning input
with system authorization. Every record stays `unqualified`; there is no update,
activation, deletion, credential or storage operation. Registering a destination
does not qualify a provider, enable recording or make any block available.
The control-plane request and receipt are
[private archive registration](archive-registration.md); this page owns the
retained fields, digest and database identity.

Version 1 accepts exactly these eleven string-keyed fields. Unknown and missing
fields fail. All tokens are bounded ASCII; no DNS or provider request occurs.

| Field | Version 1 contract |
| --- | --- |
| `schema_version` | Integer `1` |
| `provisioning_ref` | Allocation token, 1..128 bytes, begins alphanumeric; remaining characters alphanumeric or `. _ : -` |
| `generation` | Positive signed-bigint destination generation |
| `purpose` | `recording` |
| `provider` | `s3_compatible`; protocol adapter identity, not provider qualification |
| `endpoint` | Canonical HTTPS origin, lowercase DNS host, 3..253 bytes with labels at most 63 bytes; implicit port 443, no explicit port, trailing slash, credentials, path, query or fragment |
| `region` | Lowercase alphanumeric or hyphen, 1..40 bytes |
| `bucket` | Lowercase DNS-style name, 3..63 bytes; no IP literal |
| `namespace` | `recordings/v1` |
| `archive_format_version` | Integer `1` |
| `required_encryption` | `sse_s3_aes256`; a requirement, not encryption evidence |

The product assigns a UUID and `destination_sha256`: lowercase SHA-256 over
compact UTF-8 JSON containing these fields in the table order. The canonical
input contains only integers and bounded ASCII strings, so no float, Unicode
normalization or arbitrary-map ordering enters the digest. The independently
calculated synthetic digest in `ArchiveDestinationTest` guards this contract.

`provisioning_ref` and `generation` uniquely identify one retained destination.
Exact retries return that record. Conflicting input fails without updating it;
changing a destination requires a new generation. Credential rotation, policy
revision and qualification observations stay off this row. The
[qualification report](qualification-report.md) parses those claims. A
[private receipt](qualification-receipts.md) may retain the current submission
separately. Neither the report nor the receipt qualifies the binding or installs
authority. The local spool `storage_id` remains the volume-lifetime UUID and
does not identify a bucket.

`RecordingBlocks.bind_archive/4` requires a current upload handle, binding UUID
and exact destination digest. It reloads the binding under the block's existing
token, upload epoch, frozen-descriptor digest and database-time fence. The first
call binds the frozen block; an identical retry returns its retained binding;
another destination fails. A resource-level atomic validation also prevents a
non-null binding from being replaced. Lease release and reacquisition retain the
binding, and expiry before transaction completion rolls back the binding. A
restrictive foreign key prevents deletion while a block refers to it.

This is a local CNPG identity boundary. It cannot cancel a delayed remote write,
authorize object operations, attest encryption, or substitute diagnostic keys
for recorder authority. Future upload work requires separately qualified
conditional-write/encryption behavior and isolated credential custody. No SaaS
implementation or readiness acknowledgment is introduced here.

The pure contract keeper covers canonical identity and refused input. The
existing guarded recording-block database keeper owns exact registration,
conflicting retries, concurrent binders, stale/expired authority, restrictive
deletion and cleanup. It deletes only its own IDs and rechecks deletion. Its
database bodies must run in the guarded CI database lane; ordinary RBE
compilation and selection do not execute them.
