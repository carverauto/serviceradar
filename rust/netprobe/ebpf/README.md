# ServiceRadar netprobe eBPF programs

This crate contains the kernel-side programs for Phase 3 host flow attribution.
It is intentionally isolated from the userspace `serviceradar-netprobe` crate:
the loader, map pinning, and procfs correlation are implemented by later Phase 3
tasks.

Programs:

- `netprobe_tc_ingress`: TC ingress classifier for flow-table lookup and
  first-packet AF_XDP redirection.
- `netprobe_tc_egress`: TC egress classifier with the same canonical flow-table
  behavior for reverse-direction traffic.
- `tcp_rcv_state_process`: kprobe for SYN-time TCP option signatures; emits
  one `TcpSynSignatureRecord` for SYN packets seen at connection setup.
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

Socket lifecycle hooks also refresh the pinned `process_info` map keyed by TGID.
The `sock/inet_sock_set_state` tracepoint backfill has the full 5-tuple and
populates the pinned `flow_to_pid` map for later userspace joins.

Pinned map capacity bounds are fixed in the eBPF object:

- `flow_table`: 65,536 global LRU entries until the loader grows this at load
  time in the remaining Phase 3 work.
- `flow_to_pid`: 1,048,576 LRU entries.
- `process_info`: 8,192 hash entries.
- `interface_allowlist`: 1,024 hash entries.

The userspace startup path creates `/sys/fs/bpf/serviceradar/netprobe` and
chmods both `/sys/fs/bpf/serviceradar` and the `netprobe` leaf to mode `0700`
before privilege drop. The later loader work pins these maps under that
directory.

TCP SYN signatures are emitted to the `tcp_syn_signatures` ring buffer. The
record carries TTL/hop-limit, window size, MSS, TCP option kind layout, quirks,
IP version, window scale, and payload class for the userspace huginn-net
matcher.

The `flow_table` and `flow_to_pid` maps use the same canonical 5-tuple key with
the lexicographically smaller endpoint first, so both directions of a connection
share one entry and socket-layer kprobes can join with TC-written flow state.
`FlowPidRecord.local_endpoint` preserves which canonical endpoint belongs to the
local process. A zero `classified_as` means the first `FLOW_REDIRECT_BUDGET`
packets are still redirected to AF_XDP for userspace classification; nonzero
values are treated as classified and stay in-kernel. TC ingress AF_XDP redirect
uses a deterministic flow hash modulo the configured XSK queue count instead of
`skb->queue_mapping`, which is egress-only metadata on many kernels.

`include/vmlinux.h` is generated from Ubuntu 20.04 `5.8.0-23-generic` BTF, the
earliest supported kernel floor for the Phase 3 CO-RE work. See the
"Netprobe eBPF BTF header" section in the repository `BUILD.md` for the
regeneration procedure and source checksum.
