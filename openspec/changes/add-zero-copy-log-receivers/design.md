## Shared processing contract

Every receive backend feeds the same bounded parser/Zen/batcher/publisher path.
Preserve remote address, datagram/frame boundaries, timestamp behavior, limits
and accounting. TCP backpressure and UDP drops remain distinct. Bound connection
counts, frame size, incomplete-frame bytes and queued records/bytes before
scaling the listener population.

Start with batched UDP sockets and async TCP. Evaluate ordinary io_uring/
Compio independently from receive zero-copy; send zero-copy is another boundary.
Use explicit backend names and an automatic mode. Automatic selection reports
chosen backend and fallback reason. Forced zero-copy fails clearly if unavailable.

## Accelerated receive

AF_XDP uses dedicated queues/UMEM and targeted XDP redirection. Force
XDP_ZEROCOPY and verify XDP_OPTIONS_ZEROCOPY; driver advertisements alone do not
prove operation. Preserve unrelated traffic and define VLAN, checksum,
IPv4/IPv6, fragmentation and unsupported-packet handling before deployment.
Multi-buffer jumbo frames are not IP-fragment reassembly.

TCP ZC Rx retains the kernel TCP stack and requires a supporting kernel, driver,
header/data split and queue steering. Probe the operation rather than guessing
from release numbers. Feature registration is not a throughput test.
Validate encryption separately without weakening existing TLS.

## Ownership and Zen

A receive lease owns valid immutable bytes until processing releases all views.
Parse ranges without repeated string allocations. Zen's existing shared owned
strings are the first implementation; a custom NIC lease-backed Symbol needs
an upstreamable extension and semantic conformance, not an unsafe static cast.

Encode approved normalized output once into a bounded publish batch, then
release receive leases before NATS ACK retries. Rewrites/unescaping create
new bytes. TCP frames spanning chunks may require coalescing. Bound retained
capacity and refill starvation; one controlled ownership copy can be preferable
to pinning scarce NIC buffers through slow rule evaluation.

Preserve one shared native normalization implementation. Native expressions
and JavaScript nodes need separate cost profiles; arbitrary JS heap conversion
is not claimed zero-copy.

## Kubernetes and edge deployment

Support ordinary VM-backed Kubernetes workers as the primary baseline.
Inspect physical host, guest NIC and pod namespace separately. Host networking
inside a VM does not expose a hypervisor physical function. A dedicated
passthrough port or SR-IOV interface is a candidate only after validating the
actual guest/VF driver. Never detach a live management uplink for a benchmark.

Portable mode should run under restricted pods where possible. Verify
io_uring calls under actual seccomp; provide a reviewed Localhost profile if
required rather than shipping unconfined diagnostics as the default.
Accelerated mode declares its device/queue ownership, memory locking and
capabilities explicitly, scoped to collector workloads. Do not relax namespace
or worker-wide isolation for unrelated services.

## Verification

Separate capability discovery, registration, packet delivery and throughput.
Use synthetic UDP/TCP data with counted IDs, bounded time/load and cleanup.
Compare identical Zen rules, TLS, publication durability and storage/query
workload. Record per-stage losses, copied bytes, allocations, memory, CPU,
p99 searchable latency and recovery after downstream stalls.

Live inventory belongs outside source control. Commit only synthetic fixtures
and reusable test contracts. Hardware setup/reboot/rollout changes must be
planned around the selected test machine, never inferred from a pod check.
