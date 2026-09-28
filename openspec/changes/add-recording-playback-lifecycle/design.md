## Context

Consume verified recording/index state from `add-camera-recording-storage`.
Use archived-but-not-indexed states from `add-edge-recording-archive` where enabled.

## Playback, retention and holds

Expose a bounded timeline with recorded intervals and gaps, seekable playback,
and authorized time-range export. Recheck authorization when issuing short-lived
playback URLs/handles; persist neither source secrets nor signed URLs in share
links. Dashboard SDK hosts own these operations and clean up players/sessions.
Camera identity links to the same optional object identity used by map providers.

Retention deletes only eligible published segments after checking holds and active
export leases. A hold racing deletion must resolve atomically in the metadata
workflow; a hold is accepted only after durable storage policy can honor it.
Never promise a hold on JetStream-only staged bytes or bytes already deleted.
Storage lifecycle rules must not delete protected media behind the application's
back. Record deletion intent, remove objects, then verify absence and mark deleted;
retry partial failures. Playback displays gaps/expired intervals honestly.

## Dependencies and rollout

Recording lifecycle APIs/workers, browser player and dashboard camera SDK. Depends on add-camera-recording-storage; coordinates with add-edge-recording-archive and add-shared-spatial-resources. Does not block #4774.
Publish authorized APIs only after real browser seek and retention-race proof.
No live-view behavior or default recording policy changes implicitly.

## Delivery and isolation

Use treehouse and remote RBE with --config=remote; no Docker, local compilation
or new shell scripts. Automated database tests use srql-fixtures scratch DB only.
All fixtures are independently invented. Use migrations for schema changes.
Run required checks and make test before a PR; deliver every PR through no-mistakes.
