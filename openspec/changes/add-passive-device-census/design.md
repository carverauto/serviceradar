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
live /24).

**A first measurement attempt was invalid and is recorded here so nobody repeats it.** Reading
observation counts out of the journal reported 117 in 300 s, which looked like a clean 0.39/s.
It was journald's rate limiter: `RateLimitBurst=10000` per 30 s was discarding **~1.15 million
messages per 30 s**, so the true rate was roughly **38,000/s**. Any measurement taken through
the journal must check for `Suppressed N messages` lines before it can be believed.

**The real cause was that in-kernel suppression never suppressed.** The `l2_seen` LRU map held
88 well-formed 28-byte keys whose stored values matched `bpf_ktime_get_ns`
(`0x24783122F5DF7` against `/proc/uptime` 641,761,420,000,000), so inserts were landing with
correct timestamps — yet every frame was still emitted, i.e. lookups behaved as misses. The key
struct has no padding and the aya `LruHashMap` API is used as documented, so the cause is not
obvious. Suppression moved to userspace, where it is deterministic and unit-testable.

**Validated measurement, 300 s clean run, zero journald suppression in steady state:**

| Metric | Value |
| --- | --- |
| Observations | 230 (**0.77/sec**) |
| Unique MACs / (MAC, IP) pairs | 29 / 46 |
| **Max emissions for any one pair** | **5** |
| Kinds | 140 NDP, 85 ARP request, 5 ARP reply |
| Randomized MACs | 30 (13%) |
| Off-segment, refused for anchoring | 35 (15%) |

**Why this validates 60 s.** Across 300 s a 60 s refresh permits at most 5 emissions per
binding. The busiest pair emitted exactly 5, and the total is 46 × 5 = 230 — every binding
emitting exactly at the window cadence, neither leaking nor over-suppressing. Independently
confirmed against the last 120 s of steady state: 92 observations, again 0.77/s.

**Headroom.** 0.0266 observations/sec per device, so ~27/sec at 1,000 devices and ~266/sec at
10,000, against a ring holding ~21,800 of these 48-byte records.

**The window is not what makes transient devices visible.** A first sighting is always
admitted; the window only rate limits refreshes. A device present for 90 s is recorded on
arrival regardless.

**What the window could not have fixed.** Before restricting the census to ARP and NDP, routed
traffic paired the gateway's MAC with an unbounded set of remote addresses, so every new remote
IP minted a fresh key and no window value would have helped. That was a design error, not a
tuning problem.

## Open Questions

- Should `otel_log`/OCSF event emission accompany the inventory path, or is
  `DeviceSourceObservation` alone sufficient for the first cut?
- ~~Should IPv6 NDP be included now?~~ **Resolved: yes, implemented.** ICMPv6 types 133-136,
  including Router Solicitation, which a host emits as it joins the link -- the v6 counterpart
  to gratuitous ARP. NDP was 66 of 117 observations in the live run, i.e. the majority.
