# ServiceRadar object storage

This library qualifies the pinned Longshore S3 client through Rustler. It is not
yet the production archive adapter: it does not issue archive receipts, grant
uploads, publish catalog entries or authorize spool deletion. Required upstream
API work is recorded in the
[Longshore design](../../openspec/changes/add-longshore-object-storage/design.md).

## API and lifecycle

`ServiceRadarObjectStorage.open/1` accepts a trusted configuration map. Required
keys are `host`, `port`, `region`, `bucket` (nil for virtual-host addressing),
`access_key`, `secret_key`, `session_token` (nil when unused), `tls`,
`concurrency` and `buffer_size`. Credentials belong to the authorized storage
workload; do not log this map or pass it to a browser/camera sender.

Use public-root HTTPS for remote stores. Plain HTTP is accepted only for a
numeric loopback address, allowing a controlled local test peer. This version
does not expose credential-file rotation, proxy/custom-CA configuration or
multipart. Those remain qualification work, not silently ignored options.

The returned resource supports:

- `put/3`: conditional single-buffer write. A completed result is
  `{:ok, :stored}` or `{:ok, :already_exists}`.
- `fetch/2` and `fetch_range/4`: bounded reads returning bytes or
  `{:ok, :not_found}`. These are not identity-bound archive playback APIs.
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

Each buffer is 8 KiB..16 MiB; concurrency multiplied by buffer size cannot exceed
64 MiB. Longshore's TLS connections additionally reserve roughly twice this
payload capacity. Submitted PUT slices are copied into owned memory, avoiding
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
