# ServiceRadar netprobe eBPF programs

This crate contains the kernel-side programs for Phase 3 host flow attribution.
It is intentionally isolated from the userspace `serviceradar-netprobe` crate:
the loader, map pinning, and procfs correlation are implemented by later Phase 3
tasks.

Programs:

- `netprobe_tc_ingress`: TC ingress classifier for flow-table lookup and
  first-packet AF_XDP redirection. It also emits TCP SYN option signatures from
  verifier-bounds-checked packet loads, avoiding kernel `struct sk_buff` layout
  offsets.
- `netprobe_tc_egress`: TC egress classifier with the same canonical flow-table
  behavior for reverse-direction traffic.
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

Pinned map capacity bounds are explicit in the eBPF object:

- `flow_table`: 65,536 LRU entries per interface slot, with 16 interface slots
  in the object default. The Phase 3 loader should override `max_entries` before
  load to `65,536 * allowlisted_interface_count` once the allowlist is known.
- `flow_to_pid`: 1,048,576 LRU entries.
- `process_info`: 8,192 hash entries.
- `interface_allowlist`: 1,024 hash entries.

The userspace startup path creates `/sys/fs/bpf/serviceradar/netprobe` and
chmods both `/sys/fs/bpf/serviceradar` and the `netprobe` leaf to mode `0700`
before privilege drop. The later loader work pins these maps under that
directory.

TCP SYN signatures are emitted to the `tcp_syn_signatures` ring buffer for the
one-minor-version migration window and to the license-clean `p0f_signatures`
ring buffer for the in-tree p0f matcher. The p0f record carries the canonical
5-tuple plus `source_endpoint` so userspace can preserve which endpoint sent the
SYN after canonicalization. It also carries the kprobe-encoded p0f string,
observed timestamp, and ABI version.

The `flow_table` key is `(interface_index, canonical 5-tuple)` so flow-cache
pressure is scoped to the interface that owns the TC attachment. The `flow_to_pid`
map remains keyed by canonical 5-tuple alone so socket-layer kprobes and TC
programs can join without an unavailable ifindex. Canonical 5-tuples place the
lexicographically smaller endpoint first, so both directions of a connection
share one logical flow; `FlowPidRecord.local_endpoint` preserves which canonical
endpoint belongs to the local process. A zero `classified_as` means the first
`FLOW_REDIRECT_BUDGET` packets are still redirected to AF_XDP for userspace
classification; nonzero values are treated as classified and stay in-kernel. TC
ingress AF_XDP redirect uses a deterministic flow hash modulo the configured XSK
queue count instead of `skb->queue_mapping`, which is egress-only metadata on
many kernels.

`include/vmlinux.h` is generated from Ubuntu 20.04 `5.8.0-23-generic` BTF, the
earliest supported kernel floor for the Phase 3 CO-RE work. See the
"Netprobe eBPF BTF header" section in the repository `BUILD.md` for the
regeneration procedure and source checksum.
