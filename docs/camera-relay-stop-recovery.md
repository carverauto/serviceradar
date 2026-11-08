# Reading a camera relay stop outcome

Use these authenticated camera API endpoints when a stop reply was lost. Both
require `devices.cameras.view` and access to the saved relay session. They query
the original stop; they do not send another stop or change source ownership.

1. Send `POST /api/camera-relay-sessions/{session_id}/reconcile-close` with an
   empty JSON object. A `202` response returns `data.command_id`. Save that query
   UUID; it is different from the original stop operation UUID.
2. Read `GET /api/camera-relay-sessions/{session_id}/close-observations/{command_id}`.
   This reads the retained command ledger and sends no agent command. It can be
   repeated after a client restart using the same query UUID.

A successful read returns `data` with these fields:

| Field | Meaning |
| --- | --- |
| `command_id` | UUID of the read-only query |
| `query_status` | Delivery/result status of that query, independent of the stop |
| `query_completed_at` | Ledger completion time, or null while awaiting a result |
| `observation` | Validated agent stop observation, or null if the query has no successful result |
| `retirement_proven` | Always false for this API |

A queued, sent, acknowledged or running query is still awaiting a result. An
expired, failed, canceled or offline query has no usable stop observation.
An overdue nonterminal query is reported as expired even before ledger cleanup
runs. None of these states proves that the source stopped.

For a completed query, `observation.state` is one of:

| State | Meaning |
| --- | --- |
| `pending` | The captured stop has not finished locally |
| `completed` | The captured local source close finished without a recorded close error |
| `unresolved` | The captured source close reported an error |
| `unknown` | The agent no longer has an observation for that operation |

The observation includes the original `operation_id`, `relay_session_id` and
`source_incarnation_id`. Known observations also include `camera_source_id` and
`stream_profile_id`. All identities are checked against the saved session and
query. Unrelated command payloads and free-form agent messages are not returned.

`completed` is a historical local observation, not a qualified physical fence or
permission to replace a source. These endpoints never advance a relay state,
retire an owner, renew a lease or enable continuous recording. A pending
observation remains the snapshot from that query; another POST requests a new
snapshot, while another GET only reads the old one.

A `409 unknown_stop_identity` means the session lacks the saved stop UUID or
runtime incarnation. A `409 invalid_stop_observation` means a completed reply
was malformed or inconsistent; preserve the unresolved outcome. A `404` means
the session/query is absent or the query does not belong to that saved target.
`409 agent_offline` means the query could not be dispatched. `400` rejects
malformed UUIDs; authentication and authorization failures return `401`/`403`.

Agent observations survive only within the original stop deadline, at most five
minutes, and do not survive a source registry restart. Retained ledger replies
remain readable until the existing command cleanup policy removes them. A
missing record, lost query reply or changed incarnation must never be treated as
successful retirement. No automatic query retry or stop replay is performed.
