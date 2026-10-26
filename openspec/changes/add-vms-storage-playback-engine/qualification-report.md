# Archive qualification report format

`ServiceRadar.Camera.ArchiveQualificationReport.parse/1` owns the version 1
observation format shared with the Cloud provisioning work. It accepts a decoded
JSON object and returns the unchanged document, canonical JSON, `report_sha256`
and the existing destination's `destination_sha256`.

Parsing establishes content identity only. A report is a claim by its producer,
not proof that its checks ran or that its producer is authorized. Even all-passed
observations grant no readiness, credential access, admission or dispatch rights.
The immutable `ArchiveBinding` remains unqualified. This module has no database,
network, clock, credential resolver or mutation API.

## Exact version 1 input

Every field below is required. Unknown keys are rejected at every object level.
Keys are strings, versions and generations are integers, and identifiers are
case-sensitive. A token is 1..128 ASCII bytes, starting with an alphanumeric
character and then containing only alphanumerics, `.`, `_`, `:` or `-`.

| Field | Format |
| --- | --- |
| `schema_version` | Integer `1` |
| `binding_id` | Canonical lowercase UUID for the runtime's retained binding |
| `destination` | Exact version 1 `ArchiveDestination` input, including immutable provisioning reference, generation and recording purpose |
| `provider_resource_id` | 1..256 printable non-space ASCII bytes; opaque provider resource identifier |
| `endpoint_type` | Token naming the provider's endpoint class; a name is not a supported-capability claim |
| `credential` | Exact object with `reference`, positive signed-bigint `generation` and `storage_service_id`; both references are 1..256 printable non-space ASCII bytes |
| `policy_revision` | Token naming the measured policy revision |
| `operation_mode` | `mediated_immutable_archive_v1` |
| `issued_at_ms`, `expires_at_ms` | Positive signed-bigint Unix milliseconds with expiry strictly after issue |
| `result_ref` | Token naming the evidence report covering this entire context |
| `checks` | Exact observation object below |

Credential and service identifiers are opaque custody/Secret references and
workload identities, not Secret manifests or key bytes. They can include path or
URI syntax without creating a network destination. The future authenticated
integration must resolve them to custody and an isolated workload; the parser
does not resolve them or need a separate alias registry.
The destination validator remains the single owner of destination format and
digest. The report does not repeat or accept a caller-supplied destination digest.
Matching `binding_id` to the retained destination is also an integration check,
not an assertion the parser can establish.

Each observation inherits the complete report context: exact destination,
provider resource and endpoint class, policy, credential generation, storage
service and mediated operation mode. `result_ref` identifies the corresponding
evidence bundle. An observation from another identity or a direct-provider probe
cannot establish this report's claim.

## Observation meanings

Every key is required and accepts exactly `passed`, `failed`, `not_tested`,
`not_confirmed` or `unsupported`. The latter three are distinct unavailable
observations, not defaults for omitted fields. Contradictory results remain
representable: encrypted writes can pass while encryption-policy denials fail.

| Check | What a producer reporting `passed` claims |
| --- | --- |
| `intended_operations` | Intended immutable writes and verification reads succeeded through the named mediated boundary |
| `anonymous_access_denied` | Anonymous read, list and write were denied |
| `foreign_environment_access_denied` | Another environment's identity could not access this resource |
| `recorder_privilege_boundary` | Recorder cannot provision/delete storage or alter policy, lifecycle or versioning, and cannot obtain broad bucket keys |
| `reader_privilege_boundary` | Playback identity cannot upload or delete |
| `private_acl_policy` | Private ACL and policy, no public/website/wildcard grant; provider-managed limited-key statements preserved |
| `endpoint_tls_redirect_boundary` | Enforced TLS, validated allowlisted endpoint and no redirect escape |
| `browser_cors` | Only configured origins, GET/HEAD and required range headers; this does not authorize a viewer |
| `put_aes256_attestation` | Compliant PutObject requested SSE-S3 AES256 and object/HEAD evidence attested that mode |
| `multipart_aes256_attestation` | Compliant CreateMultipartUpload requested SSE-S3 AES256 and the completed object's evidence attested that mode |
| `put_missing_aes256_denied` | Encryption policy denied PutObject with the required header absent |
| `put_noncompliant_aes256_denied` | Encryption policy denied PutObject with a noncompliant header value |
| `multipart_missing_aes256_denied` | Encryption policy denied CreateMultipartUpload with the required header absent |
| `multipart_noncompliant_aes256_denied` | Encryption policy denied CreateMultipartUpload with a noncompliant header value |
| `atomic_put_no_overwrite` | Conditional PUT rejected competing writes and preserved incumbent content |
| `atomic_completion_no_overwrite` | Conditional multipart completion rejected competing writes and preserved incumbent content |
| `integrity_object_identity` | Signed checksum rejection, independent final length/digest verification and strong object/version identity succeeded |
| `conditional_ranges` | Exact identity-bound byte ranges were returned with correct status, length and content |
| `multipart_recovery` | Completion errors were recognized and exact-owned abort/reconciliation was bounded and verified |

Each encryption-policy denial must be attributable to the intended encryption
policy and paired with a successful compliant operation under the same context.
An authentication failure, unrelated permission denial, malformed request,
network failure or ambiguous evidence is not `passed`. Default encryption and
positive attestation do not substitute for a denial. For SSE-S3, this tests the
initiation header; it does not demand that header on UploadPart or completion.
The parser preserves these claims but does not validate their truth.

## Canonical content identity and limits

Recursively sort object keys by ASCII byte order and encode compact JSON, without
whitespace or a trailing newline. Escape double quotes and backslashes with a
backslash; emit every other admitted ASCII character literally, including `/`,
`<`, `>` and `&`. Do not add optional Unicode, slash or HTML escapes. Integers
use shortest decimal notation. Hash those bytes with SHA-256 and encode the
digest as lowercase hexadecimal. Values are preserved; there are no floats,
optional keys, arrays or Unicode strings in version 1. Input key order therefore
cannot change the digest. A changed observation, credential generation or policy
does change the report digest. Credential rotation leaves the separate immutable
destination digest unchanged.

The fixed schema and per-field bounds bound canonical output. The surrounding
transport must cap its raw body before decoding, reject duplicate JSON keys and
preserve integers exactly. Parsing an already-decoded object cannot recover
duplicates or precision lost by a decoder. The
[private receipt endpoint](qualification-receipts.md) applies those transport
bounds; this parser does not own a route.

Issue/expiry values record what the issuer said; parsing neither checks wall time
nor starts a validity clock. Expired observations remain useful diagnostic data.
Maximum accepted authority lifetime, correlation and conservative monotonic
expiry belong to the later authenticated eligibility check, not this format.

## Remaining integration

This is a partial delivery of product task 0.8 and Cloud proposal task 1.2.
The [private receipt endpoint](qualification-receipts.md) now persists bounded,
revisioned submissions and withdrawals. [Media authentication](media-authentication.md)
identifies the installed deployment for that listener. A receipt still does not
install storage authority.

Installed desired/applied authority and bounded transport are owned by
[init authority](init-authority.md) and [media upload](media-upload.md). This
report still does not install that authority. These nineteen observations alone
are not a complete readiness assessment. Evidence/derivative storage and Object
Lock must not be inferred from this recording report.

Existing direct-provider diagnostic results cannot be mechanically promoted to
these broader claims. In particular, the current probe deliberately reports
`cloud_ready: false`, unsupported recorder credentials and untested policy
enforcement. It does not execute the four encryption-policy denial checks or
establish the mediated workload boundary.

Before any provider adapter sends an operation, it must match the retained binding
and frozen intent, enforce current authenticated authority and isolated credential
custody, then use the existing single dispatch marker outside CNPG transactions.
Late outcomes remain admissible after timeout/revocation; neither event proves
remote cancellation. The handoff records which transport and publication steps
are still open.
