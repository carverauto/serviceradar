# Durable recording stop

The private media configuration endpoint supports one restrictive command:
stop recording admission. Existing explicit local-spool enablement and leases
continue to govern recording until a stop is installed. They grant no S3 access.
This checkpoint has no enable or resume command and does not install full media
configuration or storage authority.

## Wire contract

`PUT /v1/media/configuration` and `GET /v1/media/configuration` use the separate
[media authentication](media-authentication.md) on the private listener. The
authenticated connection supplies the installed origin; callers cannot supply
an actor, deployment reference or generation in the document.

PUT accepts exactly this versioned shape, with a 1024-byte JSON body limit:

```json
{"contract_version":1,"revision":"1","admission":"stopped"}
```

Revision is a canonical decimal string from `1` through `9223372036854775807`.
Numeric revisions, leading zeros, unsupported versions, unknown or missing
fields, arrays and duplicate keys are rejected. Encoded path segments follow
the same routing interpretation as authentication and cannot bypass the limit.
An unsupported method returns 404 before generic body parsing.

The singleton is local to this deployment's database. Its pinned origin is
provenance, never a tenant selector. The first stop pins the authenticated
deployment UUID and generation. Its digest includes every accepted document
field and that origin. A retry with identical origin, revision and content
returns the original receipt without extending a timestamp or lease. A different
deployment is rejected. Older generations cannot read or overwrite a newer
stop. A newer generation can read the retained stop but must supply a newer
revision to replace its origin; revisions never reset with generation changes.

Malformed wire documents return 400, oversized bodies 413 and unsupported media
types 415. Invalid configuration returns 400; stale or conflicting revisions,
stale generations and a pinned-origin mismatch return 409. Unavailable durable
control returns a bounded 503. Authentication failures remain 401 before parsing.
Responses are non-cacheable and never echo credentials.

## Enforcement and preservation

An idempotently initialized singleton row serializes stop with recorder acquire,
renew and block reservation, and with new upload dispatch marking. The control
row is locked before the existing ingest/claim or block/dispatch locks. Stop
commits only its own row and rejects an explicitly open caller transaction;
it never calls a worker or performs external I/O while holding that lock. No database query is added to the per-frame path.

An operation serialized before stop can complete under its existing lease.
After stop commits, new admission through those four owners fails. Generic
publication, local freeze, release and late upload observations remain possible
under their original fences. Stop neither rearms dispatch nor erases uncertain
outcomes. It cannot cancel an already marked remote operation or authorize
deleting local media.

At renewal, an active worker that receives the stopped result asks its exact
producer to drain only that recorder inbox. The producer verifies worker and
inbox identity, orders `recording_end` after already accepted media, and leaves
live viewers attached. The request waits at most five seconds or the remaining
original lease time, whichever is shorter. The worker finishes packaging, persists and seals within
its original deadline. Failure or expiry leaves recoverable journaled bytes;
it does not fabricate a frozen block or extend the lease to finish draining.

## Status and remaining authority

Status reports `contract_version`, `stop_enforced`, `desired_revision`,
`desired_digest` and `received_at`. Before a stop, the latter three are null.
Both stopped and baseline responses retain `applied_revision: null`,
`readiness: unavailable`, `reason: recording_stop_only` and
`drain_status: not_attested`. Stop enforcement is not a completed rollout or
proof that all processes and uploads have stopped. These gates apply to binaries
containing this implementation; the response cannot attest that older binaries
have retired. Cloud must verify compatible rollout and preservation separately.

Positive admission still requires the complete desired/applied content contract,
current qualification evidence, conservative expiry and revocation, budgets and
isolated storage credential custody. A future resume must fence generation and
in-flight work explicitly. Neither this command nor old qualification receipts
can supply that authority. Cloud must reconcile this status with preservation
before reporting suspend, disable or termination complete.
