# Camera relay open-command retries

Within one agent source registry, duplicate `camera.open_relay` commands share
one startup attempt. After a lost reply, an identical command returns the
original startup result. A successful receipt contains the original
`relay_session_id`, `media_ingest_id` and `lease_expires_at_unix`, even if that
source has since stopped. It is historical evidence, not a current liveness
check or permission to replace a source.

The operation key is the original command ID. Retries must retain the original
creation time, TTL and normalized session specification, including source,
profile, agent, gateway, lease, plugin, address, transport and codec settings.
Changing those values while the record is retained is a conflict. Concurrent
duplicates wait for the first attempt; cancelling a duplicate wait does not
cancel that attempt. Once the attempt has finished, its outcome is returned
even if the waiting caller was cancelled or the command deadline passed while
the open was still running, so a slow open is never reported as a timeout
after it started a source. Startup failures are retained too: a duplicate
cannot turn a failed attempt into a new camera open.

Open commands require a nonempty ID, positive creation time and TTL, and an
unexpired deadline no more than five minutes away. TTLs above five minutes are
rejected. Receipts occupy at most 4,096 entries and are retained through the
original deadline. At capacity, new operations are refused before gateway or
camera I/O; retained operations remain readable. Expired commands are refused.
The cache keeps a digest of the normalized specification rather than a copy of
its credentials. This deadline bounds admission and duplicate waits; it does
not replace the existing source lifetime or lease policy with an offline grant.

These records are process-local and disappear on registry restart. They do not
supply a durable journal or a qualified physical fence. A command identity must never be recycled or given a later
deadline after retention ends. Core does not automatically replay opens across
reconnects or restarts: that requires authenticated operation/incarnation
reconciliation and qualified ownership fencing first. Recorder pools and
continuous recording remain separate work.

## Reading a lost open outcome

With `devices.cameras.view` and access to the saved relay, send an empty JSON
object to `POST /api/camera-relay-sessions/{session_id}/reconcile-open`.
The `202` response contains `data.command_id`, a fresh query UUID. This sends
`camera.reconcile_relay_open` to the original agent, bound to the saved open
operation, relay session and source incarnation. It never resends an open.

Read `GET /api/camera-relay-sessions/{session_id}/open-observations/{command_id}`
to retrieve the retained query. The response envelope has the same fields as
[stop recovery](camera-relay-stop-recovery.md): `command_id`, `query_status`,
`query_completed_at`, `observation`, and `retirement_proven: false`. GET sends
no command and can be repeated after a caller restart. Delivery failure or an
expired query returns no observation; it does not mean startup failed.

For a successfully completed query, `observation.state` is:

| State | Meaning |
| --- | --- |
| `pending` | The original startup attempt has not returned |
| `succeeded` | That startup attempt returned success, even if the source later stopped |
| `failed` | That startup attempt returned an error |
| `unknown` | No receipt remains for that operation in this registry |

The observation contains `operation_id`, `relay_session_id` and
`source_incarnation_id`; known outcomes also include `camera_source_id` and
`stream_profile_id`. Core checks these against the session and query and returns
only those fields and the state. Source URLs, credentials and raw failure
messages are not exposed by this projection. Even `failed` is not proof that
all partial resources retired. None of these states renews a lease, changes
ownership, proves current liveness or authorizes a replacement.

A pending observation is a snapshot: another GET returns the same snapshot;
a fresh POST asks for a newer one. Agent receipts expire at the original open
deadline and are lost on restart. A new registry rejects the old incarnation.
Ledger replies remain readable until normal command cleanup removes them.

`409 unknown_open_identity` means the session lacks a saved open UUID or source
incarnation. This includes opens whose admission never recorded an incarnation;
do not guess one or replay the open. `409 invalid_open_observation` rejects a
malformed or mismatched reply. `404` means the session/query is missing or the
query belongs to another target. `409 agent_offline` reports dispatch failure;
invalid UUIDs return `400`, and authentication/permission failures return
`401`/`403`. There is no automatic replay, ownership recovery or restart fence.
