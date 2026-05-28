# ServiceRadar netprobe eBPF programs

This crate contains the kernel-side programs for Phase 3 host flow attribution.
It is intentionally isolated from the userspace `serviceradar-netprobe` crate:
the loader, map pinning, and procfs correlation are implemented by later Phase 3
tasks.

Programs:

- `tcp_connect`: kprobe for outbound TCP connect attempts.
- `inet_csk_accept`: kretprobe for accepted inbound TCP sockets.
- `tcp_close`: kprobe for TCP socket close.
- `udp_sendmsg`: kprobe for outbound UDP sends.
- `udp_recvmsg`: kprobe for inbound UDP receives.
- `inet_sock_set_state`: `sock/inet_sock_set_state` tracepoint backfill with
  the socket tuple fields exported by the kernel tracepoint.

Events are emitted to the `flow_events` ring buffer. The userspace loader should
pin maps under `/sys/fs/bpf/serviceradar/netprobe/` and consume
`FlowAttributionRecord` by version.
