# Bounded local capture

`ServiceRadarCoreElx.CameraRecording.Capture.once/1` is a private release-callable
administration entry point for one existing relay on its current owner core.
It accepts only the relay UUID. It does not open a relay, publish objects, start
a schedule, rotate blocks, retry capture or resume a durable recording stop.

## Installed configuration

Capture remains disabled by default. The owner core must have:

- `SERVICERADAR_CAMERA_RECORDING_ENABLED=true` explicitly installed;
- `SERVICERADAR_CAMERA_RECORDING_SPOOL_ROOT` set to an absolute private local
  spool directory;
- `SERVICERADAR_CAMERA_RECORDING_STORAGE_ID` set to that storage lifetime UUID.

The spool must already have been provisioned with `Storage.initialize/2` on its
intended persistent filesystem. The chart does not yet provide a dedicated
recording spool mount; setting environment values alone does not provision one.
The ordinary ephemeral `/tmp` mount is not a persistent recording volume. Capture
calls the existing verifier: it never creates, changes or repairs the storage
identity marker. It does not derive the
UUID from the pod, process, relay or directory name. Startup configuration alone
does not start a recorder or grant archive storage authority.

A release operator invokes `Capture.once/1` through the existing trusted release
RPC surface on the owning core, supplying the selected relay UUID. There is no
new public HTTP endpoint or browser permission bypass. A request sent to another
core cannot manufacture a local media pipeline.

## Admission, bounds and result

The coordinator reads the persisted relay and current ingest owner. The existing
worker rechecks that ownership, resolves the exact local relay/ingest pipeline,
verifies the storage marker and obtains its own independently fenced recorder
claim and consumer lease. It retains the existing durable-stop check. Source,
profile, recorder epoch and block sequence come from those owners; callers
cannot supply claim tokens, metadata identity or file paths.

The request captures at most three complete fragments, at most 16 MiB of media,
with initialization limited to 1 MiB and each fragment limited to 4 MiB. These
are ceilings, not a promise of three fragments or thirty seconds of content.
The thirty-second monotonic budget begins before relay lookup and worker start.
It caps inbox lease deadlines even when the normal recorder lease renews.
Cancellation or expiry does not seal an incomplete outcome into success.

The short-lived coordinator monitors its caller and has an independent runtime
expiry timer, which also interrupts blocked lookup or supervisor calls. The
worker monitors that coordinator and has the same absolute deadline. A caller that disappears, or a
supervisor start request that finishes after its coordinator has timed out,
cannot leave a recorder renewing indefinitely. The existing worker supervision,
unique owner registry and four-worker admission cap remain authoritative.

Only a successful `RecordingBlocks.freeze/5` supplies the stopped notification's
block ID. The administration call returns `{:ok, %{block_id: id}}` only from that
receipt while its request budget is still current. It returns a bounded error
otherwise. A status snapshot, file on disk or incomplete journal cannot produce
this success. Capture UTC remains explicitly unknown.

A success is a frozen local receipt. The worker's existing consumer-release and
idle-close teardown follows the notification and has its own one-second external
work budget. Success does not assert that teardown has already completed; lease
expiry and reaping remain the fallback if cleanup cannot finish. An independent
viewer retains its consumer and live stream. Cancellation, timeout or an
ambiguous result can leave local bytes, or a previously committed block, for
reconciliation. This entry point never deletes those bytes or retries them.

## Archive boundary and validation

Local freeze does not imply upload, provider qualification, publication or
playback availability. The existing qualified archive binding, independently
fresh init/media/manifest authorities, isolated executors and canonical
publication proofs are still required. This checkpoint performs no provider I/O
and installs none of that authority.

The existing `RecordingWorkerIntegrationTest` owns the synthetic qualification:
actual generated H264 traverses the managed pipeline and real worker, finite
capture returns a frozen block with independently probed media, worker exit and
consumer cleanup are observed separately, and a viewer continues receiving.
Additional cases cover caller loss with preserved local bytes, a stalled start
across the actual thirty-second budget, and disabled/durably stopped admission.
Its prior lease, marker, drain and freeze-race assertions remain intact. Database
execution belongs to the guarded Core fixture workflow; compilation or selection
checks alone do not prove these scenarios ran. No live-camera fixture is used.
