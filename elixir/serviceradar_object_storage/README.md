# ServiceRadar object storage

This library wraps the pinned Longshore S3 client through Rustler. It is the
transport behind the opt-in `:longshore` camera archive adapter in
`ServiceRadarCoreElx.CameraStorage`, which owns verification and receipts; this
library itself does not issue archive receipts, grant uploads, publish catalog
entries or authorize spool deletion. The contract is recorded in the
[Longshore design](../../openspec/changes/add-longshore-object-storage/design.md).

## API and lifecycle

`ServiceRadarObjectStorage.open/1` accepts a trusted configuration map. Required
keys are `host`, `port`, `region`, `bucket` (nil for virtual-host addressing),
`access_key`, `secret_key`, `session_token` (nil when unused), `tls`,
`concurrency` and `buffer_size`. Credentials belong to the authorized storage
workload; do not log this map or pass it to a browser/camera sender.
Missing, unknown or incorrectly typed fields return `{:error, :bad_config}`.

Use public-root HTTPS for remote stores. Plain HTTP is accepted only for a
numeric loopback address, allowing a controlled local test peer. This version
does not expose credential-file rotation, proxy/custom-CA configuration or
multipart. Those remain qualification work, not silently ignored options.
Longshore requires registered buffers; `pin_buffers` is unsupported and rejected.
Prepare node memlock limits using the
[media-storage runbook](../../docs/media-storage-seccomp.md).
Native initialization errors return `{:error, {:io_setup_failed, detail}}`,
preserving Longshore's local OS/setup diagnostic even when it wraps the errno.

The returned resource supports:

- `put/4` and `put/5`: verified single-buffer write (`longshore_s3::Client::put`)
  defaulting to `%{timeout_ms: 30_000}` (`Budget::once`). Options require exact
  keys `%{no_clobber: boolean(), encryption: nil | :aes256, checksum: :none | :crc64nvme | {:crc64nvme, non_neg_integer()} | {:sha256, <<_::256>>}}`.
- `head/3` and `head/4`: verified metadata probe (`longshore_s3::Client::head`)
  defaulting to `Budget::once`, taking `%{etag: nil | binary(), version: nil | binary()}`.
- `get/4` and `get/5`: verified full or inclusive byte-range read
  (`longshore_s3::Client::get`) defaulting to `Budget::once`, taking `nil | {first, last}`
  and `%{etag: nil | binary(), version: nil | binary()}`. Response body bytes are
  populated only on HTTP `200` or `206` so error XML bodies are never returned as
  object bytes.
- `ServiceRadarObjectStorage.Session`: supervised `GenServer` owner that submits
  verified `put`, `head`, and `get` calls from its own process, correlates
  `{:longshore_reply, reference, result, {queue_us, operation_us}}` without
  stranding late multi-MiB replies in caller mailboxes, and notifies admission
  controllers when `owner_token` I/O drains.
- `put/3`, `fetch/2`, and `fetch_range/4`: qualification helpers retained for
  standalone probes.
- `close/1`: stops admission and drains existing work; returns `:closing`.
- `info/1`: reports admission state, outstanding operations, remaining workers
  and buffer size. Shutdown finishes when admission is closed and workers is zero.

An admitted operation returns `{:ok, reference}`; completion arrives at the
calling process as
`{:longshore_reply, reference, result, {queue_us, operation_us}}`.
The timing pair measures native queue wait and operation execution, not total
Elixir submission/copying or end-to-end recording latency.

A caller's timeout or exit does not cancel Longshore I/O. Capacity stays charged
until the worker completes, and a late reply is possible. Treat a missing or
failed mutation reply as unknown. Do not add automatic retry or fallback to
another transport. An operation owner should remain supervised and keep its
request correlation until completion.

## Resource limits

There are at most two live clients per VM, including draining clients. Each
client uses one Longshore I/O thread and 1..16 fixed worker threads. There are no
unbounded admission waiters. Submitted plus executing operations cannot exceed
the selected concurrency. A busy client returns an error immediately.

Each requested buffer is 8 KiB..16 MiB; concurrency multiplied by requested size
cannot exceed 64 MiB. The pinned Longshore implementation raises native buffer
size to at least 256 KiB for TLS and allocates two additional native buffers per
connection. With this wrapper's equal connection and buffer counts, budget
roughly `3 * concurrency * max(buffer_size, 256 KiB)` for TLS native buffers,
plus small per-connection buffers. The requested size still bounds API payloads.
Submitted PUT slices are copied into owned memory, avoiding
retention of an arbitrarily large BEAM parent binary; workers copy into native
buffers. GET delivery also copies. This is bounded, not a zero-copy claim.
Include worker stacks, TLS overhead and copied results in the process budget.
Delivered binaries subsequently retained by callers are outside client admission.

Client resources hold queue senders rather than native I/O handles. Close or
resource collection closes the sender, workers drain, and the final worker
drops the Longshore client off BEAM schedulers. Initialization runs on a dirty
I/O scheduler. Large input copying runs on a dirty CPU scheduler.

## Remote qualification

```
bazel test --config=remote //elixir/serviceradar_object_storage:unit_tests
bazel test --config=remote //elixir/serviceradar_object_storage:quality_check
```

The test executes the loaded NIF against an independently controlled HTTP peer,
checks actual request/response bytes and withholds a response to test caller
exit and draining. It must fail when the Linux executor cannot initialize
io_uring; an unsupported environment is not a passing round trip.

The real pod still needs Linux/kernel, seccomp and memlock qualification. TLS,
real-provider behavior, multipart, service restart and performance remain
separate gates. Follow the
[benchmark protocol](../../openspec/changes/add-longshore-object-storage/benchmarks.md)
for native/Rustler comparisons and full recording measurements.

### Run the same tests in a prepared pod

Build and export the qualification release through declared Bazel outputs:

```sh
bazel run --config=remote -c opt //build/local_artifacts:longshore_qualification
```

The archive is `build/local_artifacts/artifacts/longshore-qualification.tar.gz`.
It includes the compiled library, NIF, ERTS and ExUnit. It is a test artifact,
not a replacement for the production media-storage release.

Create a disposable pod using an approved runtime image, the media-storage
UID/GID and security settings, a writable scratch volume, and a prepared node.
Do not mount provider credentials for the loopback tests. Restrict ingress and
egress; the synthetic peer runs inside the test VM on loopback. After admission,
inspect the actual pod seccomp profile: an admission policy may replace the
requested profile. Check the process's effective memlock limit.

Copy the archive and this directory's `test/` sources from the same checkout
into the pod, extract the archive to `/work/release`, and put the tests under
`/work/tests`. Execute:

```sh
/work/release/bin/serviceradar_object_storage eval 'ExUnit.start(autorun: false); Code.require_file("/work/tests/config_test.exs"); Code.require_file("/work/tests/object_storage_test.exs"); result = ExUnit.run(); System.halt(if result.failures == 0, do: 0, else: 1)'
```

Require a zero exit status and read the test count and failures. Keep the image
digest, source revision, effective security profile, limits and results in
private operational evidence. Remove the pod, its network policy and exported
archive after qualification. A successful pod run does not qualify a different
CI executor sandbox; that environment must permit the same native operations.

### Bounded provider probe

The same export target also writes `artifacts/longshore-round-trip.exs`.
Run it only in an operator-approved provider test scope. Supply a private JSON
file containing exactly the NIF configuration fields (TLS must be true), a sealed
MP4 of at most 16 MiB that fits the configured buffer, and a new output path:

```sh
LONGSHORE_QUAL_CONFIG=/work/private-client.json \
LONGSHORE_QUAL_INPUT=/work/sealed-clip.mp4 \
LONGSHORE_QUAL_OUTPUT=/work/readback.mp4 \
  /work/release/bin/serviceradar_object_storage eval 'Code.eval_file("/work/longshore-round-trip.exs")'
```

The probe conditionally writes one random key below `qualification/longshore/`,
verifies full SHA-256 and ranged readback through the NIF, and saves the verified
bytes without overwriting another file. It reports the key before dispatch and
retains both the input and object even on failure. It adds no application-level
retries; Longshore's internal retries still apply. Decode the output independently.
No catalog entry or archive receipt is issued, and this probe does not qualify
browser playback, production authority, or performance.
