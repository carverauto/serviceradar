# Bounded archive upload dispatch observations

`Camera.ArchiveUploads` retains one dispatch record per immutable object intent.
`prepare_dispatch/5` accepts the existing upload lease, object role, operation
(`:put_object` or `:create_multipart_upload`), and a TTL of 1..300000 milliseconds.
The coordinator rederives the complete object intent under the recording block
lock. It derives a logical request digest and inserts one dispatch row. The
primary key is the resource default on `uuid_primary_key :id`; `prepare` does
not accept `:id`. The row retains the original upload epoch, token fingerprint,
internal actor ID and deadline. A retry returns that same record; a changed
actor, operation or lease cannot replace it. Increasing the requested TTL
never extends the retained cap.

`mark_dispatch/3` takes the [recording-control](recording-control.md) fence
before the block lock, then the block lock before the dispatch lock, and
rechecks the complete intent. The retained operation deadline and the original
locked upload deadline both bound the operation using fresh database time. Only the first
committed marker returns `{:ok, {:marked, record}}`; a repeat inside the window
returns `{:ok, {:already_marked, record}}`. An expired window returns an error,
even when the upload lease has been renewed. The four public dispatch mutations
reject ambient database transactions so their successful returns cannot precede
an outer rollback. `RecordingBlocks.with_current_upload/4` owns the additional
deadline cap; existing `/3` callers retain their lease behavior.

This marker is local bookkeeping. It is not permission to send to an unqualified
destination. The [init](init-authority.md), [media](media-upload.md) and
[manifest](archive-publication.md) protocols own provider authorization and
verification outside database transactions. Each retains the actual wire
contract; this logical digest is not an HTTP signing digest. Losing a response after marking leaves unresolved work and never grants
another send. In particular, an unknown multipart creation cannot recover or
invent its remote upload ID.

`observe_unknown/3` and `observe_response/4` lock only the dispatch record. They
require the original lease identity and the same trusted internal system actor
that prepared it, but do not require that lease to remain current. The actor is
derived from the authenticated internal caller's options, never a dispatcher ID
in an external payload. The existing system-actor map is an internal trust
boundary, not network authentication; these functions must not be exposed as
unauthenticated routes. The low-level Ash actions are trusted persistence
primitives, as with upload intent; application callers use the coordinator.

Unknown and response facts are independent. Either may arrive first, including
after a replacement uploader acquires the block. A response contains a numeric
HTTP status (200..599) and optionally bounded `etag`, `version_id`, `upload_id`
and `request_id` strings. Unknown fields and raw bodies/headers are refused.
A successful multipart response requires an upload ID; a PUT response cannot
contain one. The JSON representation is bounded to 4096 bytes; the database
also bounds stored JSON to 8192 bytes. No response establishes verified remote
bytes or archive availability.

Exact response retries preserve the first response and timestamp. A different
response commits its digest and a permanent conflict timestamp while retaining
the original receipt, then returns an error after commit. Later retries cannot
clear that conflict. At most the first receipt and first conflict digest are
stored, avoiding an unbounded observation log. A timeout observation can still
be recorded after conflict without declaring the response trustworthy.

The Ash resource and generated migration enforce one dispatch per intent,
restrictive retention, immutable identity, one-way observation fields and
bounded deadlines/evidence. `update_camera_upload_dispatch_schema` owns the
generated schema. The existing upload integration suite owns dispatch races,
late observations, refusal paths and restrictive cleanup; the recording-block
suite owns rollback across the additional deadline. Their database cases must
run in sanctioned guarded PR CI; compilation alone is not their evidence.
