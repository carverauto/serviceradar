## 1. Portable receive
- [ ] 1.1 Specify frame/connection/queue byte bounds and backend-selection config.
- [ ] 1.2 Implement batched UDP and async TCP with shared processing and source metadata.
- [ ] 1.3 Compare ordinary io_uring/Compio against the portable baseline.

## 2. Accelerated receive
- [ ] 2.1 Add AF_XDP capability, forced binding and synthetic packet-delivery tests.
- [ ] 2.2 Implement packet handling and bounded buffer leasing with cleanup.
- [ ] 2.3 Test ZC Rx on a supporting kernel/device and integrate kernel TCP framing.
- [ ] 2.4 Compare shared owned Zen strings against a lease-backed extension before selecting a fork.

## 3. Kubernetes and performance
- [ ] 3.1 Validate restricted portable pods and a narrowly scoped io_uring seccomp profile.
- [ ] 3.2 Package accelerated device/capability requirements and explicit/automatic fallback reporting.
- [ ] 3.3 Verify overload, shutdown, MTU/fragmentation, TLS and buffer reuse.
- [ ] 3.4 Benchmark receive and durable searchable throughput with equivalent downstream work.
- [ ] 3.5 Model every lock-free structure shared between a receive thread and workers with Loom (https://github.com/tokio-rs/loom) in the change that adds it: buffer leases and their return (2.2), and any ring or queue between receive and processing. Loom does not model the Tokio scheduler, so async paths are covered by property tests instead.
