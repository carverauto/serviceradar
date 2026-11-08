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
cancel that attempt. Startup failures are retained too: a duplicate cannot turn
a failed attempt into a new camera open.

Open commands require a nonempty ID, positive creation time and TTL, and an
unexpired deadline no more than five minutes away. TTLs above five minutes are
rejected. Receipts occupy at most 4,096 entries and are retained through the
original deadline. At capacity, new operations are refused before gateway or
camera I/O; retained operations remain readable. Expired commands are refused.
The cache keeps a digest of the normalized specification rather than a copy of
its credentials. This deadline bounds admission and duplicate waits; it does
not replace the existing source lifetime or lease policy with an offline grant.

These records are process-local and disappear on registry restart. They do not
supply a durable journal, a read-only open-reconciliation API, or a qualified
physical fence. A command identity must never be recycled or given a later
deadline after retention ends. Core does not automatically replay opens across
reconnects or restarts: that requires authenticated operation/incarnation
reconciliation and qualified ownership fencing first. Recorder pools and
continuous recording remain separate work.
