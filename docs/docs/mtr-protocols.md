---
title: MTR Probe Protocols
---

# MTR Probe Protocols

ServiceRadar's MTR (My Traceroute) can probe a path with ICMP, UDP, or TCP.
The three protocols often report different paths and different hop counts to
the same target. This page explains why, and how to read the numbers.

## How each protocol finds the target

| Protocol | Probe | Intermediate hops answer with | The target answers with |
| --- | --- | --- | --- |
| `icmp` | ICMP Echo Request | ICMP Time Exceeded | ICMP Echo Reply |
| `udp` | UDP datagram to a high port (33434 and up) | ICMP Time Exceeded | ICMP Port Unreachable |
| `tcp` | TCP SYN to `tcp_port` (default 443) | ICMP Time Exceeded | TCP SYN-ACK (port open) or RST (port closed) |

A TCP trace counts the target as reached when it answers the SYN at all.
SYN-ACK and RST both mean the target's TCP stack replied. If nothing answers,
the port is filtered somewhere on the path, and the trace is not reached.

On Linux agents with raw-socket access, every TCP probe in a trace uses the same
source and destination ports. Only the TTL and the TCP sequence number change.
Agents without raw-socket access (and macOS agents) fall back to kernel
`connect()` probes, which use a fresh source port for each probe.

## Reading hop counts

Each trace records three numbers:

- **Total hops**: the hop rows the trace recorded.
- **Last responding hop**: the deepest hop that sent any reply.
- **Probed hops**: the deepest TTL that was probed.

When the target is reached, all three describe the path: the UI shows
"Reached in N hops". When it is not, probing continues past the last reply
until the run's hop limit, time budget, or consecutive-unknown limit ends it.
The total then measures how long probing ran, not how long the path is. The
UI shows these traces as "No reply past hop N (M probed)" and folds the silent
tail into a single row.

An unreached TCP trace commonly looks "longer" than a reached ICMP trace of the
same path. That is almost always this effect: the TCP port is filtered, so the
target never answers and probing runs on to the limit. Compare the **last
responding hop** of the TCP trace with the ICMP trace's length before
concluding the path changed.

## Why reached traces can still differ

Even when every protocol reaches the target, paths and depths can differ:

- **ECMP hashing.** Routers that spread traffic over equal-cost paths hash on
  the protocol and ports. ICMP, UDP, and TCP flows can each take a different
  member of the same ECMP group, and show different routers at the same hop.
- **Per-protocol filtering.** A router may answer ICMP probes but drop TCP or
  UDP probes (or rate-limit their Time Exceeded replies). The hop then appears
  as `???` for one protocol only.
- **Middleboxes.** A firewall or load balancer can answer a TCP SYN on behalf of
  the target, which ends the TCP trace early at the middlebox. A firewall can
  also reply with ICMP Destination Unreachable (for example "administratively
  prohibited"); the hop that sent it is labeled with the reason.
- **Fallback probing.** On agents that use `connect()` probes, each probe is a
  new flow, so ECMP may place consecutive TTLs on different paths.

## Choosing a TCP port

Pick a port that the target listens on, or that the path is expected to admit.
A closed port is fine: the target's RST still marks it reached. A port dropped
by a firewall is not fine, because the trace can never reach the target. 443 is
the default because edge policies most often admit it.

## TCP handshake diagnostics

Agents that can craft raw TCP segments (Linux with `CAP_NET_RAW`) end every
TCP trace with a short handshake phase: `probes_per_hop` SYNs sent at the
target's TTL, each re-sent up to `tcp_syn_retries` times (default 1, at most 3)
when unanswered. The trace detail and the device MTR tab show the result in a
TCP Handshake panel. These are measurements of active SYN probes, not of
observed application traffic:

- **SYN sent**: handshake SYNs, retransmissions included.
- **SYN-ACK / RST**: attempts the target answered with SYN-ACK, or with RST
  (port closed or rejected).
- **SYN drop**: attempts that got no answer after every retransmission, as a
  share of attempts (a first SYN plus its retries is one attempt).
- **Retx**: SYNs re-sent after the probe timeout, and attempts answered only
  after a retry (loss on the first try).
- **Ack anomalies**: replies whose acknowledgement matches no SYN that was sent
  (sequence rewriting, a SYN proxy or another middlebox), and repeated SYN-ACKs
  for one attempt (the target re-sent it, which points at return-path loss).
- **Handshake RTT**: SYN to SYN-ACK or RST time at the destination.
- **Server response**: the handshake RTT average minus the RTT average of the
  last transit hop, floored at zero. It estimates time spent in the target
  rather than on the path, and is empty when either side is missing.

Agents that fall back to `connect()` probes, and agents older than this
feature, do not run the phase; the panel says the diagnostics are unavailable
rather than showing zeros. Hop tables also list replies by kind: Time Exceeded
(TE), Destination Unreachable, SYN-ACK and RST.

The same figures are queryable in SRQL, for example
`in:mtr_traces protocol:tcp tcp_syn_drop_pct:>0` or
`in:mtr_hops reply_rst:>0`.

See [Agent Configuration](./agent-configuration.md) for the MTR check settings,
including `tcp_port`.
