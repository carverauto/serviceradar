## Context

netprobe already runs where this work belongs: XDP + TC classifiers on the host interface,
`CAP_NET_RAW`/`CAP_NET_ADMIN`/`CAP_BPF`/`CAP_PERFMON`, and a DHCPv4/DHCPv6 parser. It sees
every frame on the segment and currently uses almost none of that for device discovery.

The alternative considered and rejected was reviving the abandoned mDNS collector on
`feature/mdns-collector` (GitHub #3848) as the discovery mechanism. Investigation showed it
cannot serve this goal:

- It parses only `A`, `AAAA` and `PTR` records — no `TXT`, so the model/manufacturer strings
  that identify a device are discarded, and no `SRV`.
- Its `MulticastGroups` config is dead: referenced exactly once, in a log line
  (`listener.go:69`). The socket is opened with `net.ListenMulticastUDP(..., ListenAddr)`,
  and Go derives the group to join from that address. With the package's own default
  `ListenAddr: "0.0.0.0:5353"` the call fails with `setsockopt: invalid argument` — **the
  collector cannot start with its own defaults.**
- Its listener tests exercise `rrToRecordsStatic`, a byte-identical copy of the production
  mapping function, so the socket path, dedup integration and shutdown have no coverage;
  `publisher.go` has no test file.
- It carries a send-on-closed-channel shutdown race, a flush-on-cancel that always expires,
  and per-message synchronous publishes described as batching.
- It depends on `github.com/miekg/dns`, which is absent from `go.mod`, `go.sum` and
  `MODULE.bazel` on staging, and it never had a `BUILD.bazel`.

mDNS remains worth doing as *enrichment* for devices that announce services, but it is a poor
census: only a subset of devices speak it, and the recovered implementation is a prototype.

## Goals / Non-Goals

- **Goal:** observe every device that appears on the segment, including devices present for
  seconds, without emitting traffic.
- **Goal:** bind IP to MAC wherever the segment permits it.
- **Goal:** make passive observations queryable inventory rather than probe-internal state.
- **Non-Goal:** device *type* classification. The Satori corpus and DHCP fingerprint axes are
  left untouched; labelling what a device *is* comes later, informed by mDNS (#3848).
- **Non-Goal:** cross-segment discovery. Off-segment, the observer sees the router's MAC.
- **Non-Goal:** replacing sweeps. Passive census and active sweep answer different questions.

## Decisions

**Read `h_source` rather than probing for the MAC.** Every frame already carries the sender's
MAC. Three mechanisms were considered: reading the Ethernet header (zero cost, exact
correlation); reading the kernel neighbour table via `/proc/net/arp` or `RTM_GETNEIGH` (cheap,
unprivileged, but can be stale or unpopulated on a passive host); and an active probe to force
ARP resolution (emits traffic, and fails for precisely the transient devices that motivate
this change, caching absence). The first is strictly better wherever netprobe runs; the second
is a reasonable fallback for hosts without netprobe; the third is opt-in only.

**Parse ARP as the completeness backstop.** mDNS covers Apple/Google/IoT that announce. DHCP
covers anything taking a lease. ARP covers everything else, including static-IP printers and
embedded devices — it is the only signal that is effectively universal on IPv4.

**Randomized MAC is a classification, not a filter.** The observation is still recorded; what
changes is its weight in identity. Discarding randomized MACs would lose real presence data,
and trusting them would mint a device per rotation. Detection is a single bit test on the
first octet, so this is deterministic rather than heuristic.

**Passive observations enrich, never create.** This follows the existing conclusion from the
earlier mDNS proposal ("Do not create new devices from mDNS alone") and the active-IP-conflict
work, where anchorless devices claiming IPs caused sustained production problems. A census
that mints devices from passive traffic would reproduce that at higher volume.

## Risks / Trade-offs

- **Volume.** ARP is chatty. Observation emission needs suppression comparable to the existing
  dedup approach, or the inventory path is flooded. → Bound emission per (MAC, IP) per window;
  measure before enabling broadly.
- **Spoofing.** Passive observation believes what it sees. A host can forge ARP. → Mitigated by
  passive observations being weak identity signals that cannot create or merge devices.
- **Segment coverage becomes a deployment question.** Operators will reasonably read "sees
  every device" as global. → Documented explicitly; per-segment netprobe placement is required.
- **Randomized-MAC volume is unknown.** On a guest-wifi segment most devices may be randomized.
  → Classification lands before the census is enabled broadly, so the ratio is measurable.

## Migration Plan

No schema migration. `DeviceSourceObservation` already carries `mac`, `hostname`, `ip`,
`vendor_name`, `model` and `device_type`.

Rollout is observe-only first: land parsing and emission behind configuration, measure
observation volume and the randomized-MAC ratio on a real segment, then enable enrichment of
existing devices. Identity behaviour changes only after the randomized-MAC classification is
in place.

## The ARP/NDP suppression window: 60 seconds, measured

Set empirically on alma-test01 (AlmaLinux 9.8, kernel 5.14, SELinux Enforcing, `ens18` on a
live /24), not chosen from theory.

**The window works exactly as specified.** Over a 300 s clean run, the busiest
`(MAC, IP)` pairs emitted **exactly 5 times each** -- the arithmetic maximum for a 60 s
refresh across 300 s. Suppression is neither leaking nor over-suppressing.

**Measured volume, 300 s:**

| Metric | Value |
| --- | --- |
| Observations | 117 (**0.39/sec**) |
| Unique MACs | 29 |
| Unique (MAC, IP) pairs | 44 |
| Kinds | 66 NDP, 49 ARP request, 2 ARP reply |
| Randomized MACs | 12 (10%) |
| Off-segment (router-forwarded, refused for anchoring) | 13 (11%) |

**Why 60 s is the right value, and the headroom:**

- Per-device cost is **0.0134 observations/sec**. Extrapolating: 1,000 devices is ~13/sec and
  10,000 devices ~134/sec. The 1 MiB ring holds ~21,800 of these 48-byte records, so even the
  10k case has orders of magnitude of headroom.
- It is not what makes transient devices visible. A first sighting is **always** emitted; the
  window only rate limits refreshes. A device present for 90 s still appears immediately, and
  produces about two observations, which also evidences how long it stayed.
- It matches the kernel's own neighbour `gc_stale_time` default, so the census emits roughly
  once per natural ARP re-query cycle instead of discarding most of them.
- Shortening it buys `last_seen` precision that inventory does not use; lengthening it makes
  `last_seen` stale enough to misreport a present device as gone.

**What the number would have been without the ARP/NDP restriction:** ~400 observations/sec
from only 41 MACs, because routed traffic pairs the gateway's MAC with an unbounded set of
remote addresses, so every new remote IP minted a fresh suppression key and the cache never
suppressed anything. The three-orders-of-magnitude difference is the restriction, not the
window -- no window value would have fixed it.

## Open Questions

- Should `otel_log`/OCSF event emission accompany the inventory path, or is
  `DeviceSourceObservation` alone sufficient for the first cut?
- ~~Should IPv6 NDP be included now?~~ **Resolved: yes, implemented.** ICMPv6 types 133-136,
  including Router Solicitation, which a host emits as it joins the link -- the v6 counterpart
  to gratuitous ARP. NDP was 66 of 117 observations in the live run, i.e. the majority.
