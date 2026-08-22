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

## Decision D1: census observations reach core via ResultsRouter, not JetStream

**Decided: the JetStream-first rule does not cover passive device observations.** They travel
netprobe → agent → gateway `StreamStatus` → `ResultsRouter`, the same path every other device
discovery source already uses.

Grounds, each verified in the tree rather than assumed:

- The rule's normative text is *"Metric Ingestion via JetStream"*
  (`openspec/specs/observability-signals/spec.md:552-556`), and its stated reason is that a
  metric landing in a hypertable is invisible to real-time consumers.
  `platform.device_source_observations` is a **current-state relational table** with an FK to
  `ocsf_devices.uid`, not a series.
- **Every** device-discovery source bypasses JetStream today — sync, sweep, mapper,
  mapper_interfaces, mapper_topology, bumblebee and endpoint_inventory all land via
  `ResultsRouter` (`results_router.ex:223-262`). The census spec asks for exactly that parity:
  *"queryable alongside every other discovery source"*.
- The gateway is **deliberately not a general NATS producer**. Its publish allowlist is
  `metrics.*` / `otel.*` / `logs.otel` / `$JS.API.>` only, above a comment saying so
  (`helm/serviceradar/templates/nats.yaml:263-272`). The one inventory publisher that exists,
  `inventory.k8s.public_endpoints`, is **absent from that allowlist** and absent from
  `gateway_publisher_enabled?` — an unproven lane, not a pattern to follow.

**Counter-argument considered.** `add-adhoc-network-scan` D1 deliberately extended the rule to
non-metric scan results, republishing onto `scans.results.<scan_run_id>`. That precedent is
real, but its payload is availability/RTT/port-state — measurements over time. A
`(mac, ip, ifindex, seen)` sighting that mutates current-state inventory is not the same class.

**Reversal seam.** If this is overruled, the delta is confined to one place: a
`DeviceCensusPublisher` in the gateway, the matching NATS grants, and an EventWriter
stream/processor calling the same ingestor. Nothing else in the design changes.

## Decision D2: delivery is a periodic complete snapshot, not a per-observation stream

`DeviceSourceObservationIngestor.ingest/4` returns `:ok` **without touching the database**
unless `metadata.snapshot_complete == true`
(`device_source_observation_ingestor.ex:64`, `:492-493`). A per-observation feed would write
nothing at all.

netprobe therefore keeps a userspace census table with TTL eviction and emits a *complete*
snapshot per `(agent, interface)` on a cadence. This is not a workaround: it makes
`present: false` / `absent_since` mean "netprobe evicted this binding", rather than "this
binding happened to be quiet during one tick".

## Decision D3: the randomized-MAC guardrail is source-scoped, NOT global

The obvious implementation — teach `Ids.generate_deterministic_device_id/1` and
`has_strong_identifier?/1` to ignore locally administered MACs — **is unsafe**, and the tree
says why: `identity/mac.ex:69-71` documents that locally administered MACs legitimately come
from *"virtualization, Docker, overlay networks"*. Devices minted historically on an LAA MAC
seed would stop re-deriving their UID and fall through to a different identity. That is a
silent migration hazard affecting VMs and containers, far outside this feature.

The guardrail is therefore applied at the **source** boundary, reusing a seam that already
exists for exactly this shape: `Sync.SourcePolicy.include_mac_identifier?/1`
(`sync/source_policy.ex:34-38`) already restricts mapper-like sources to primary/management/
chassis MACs, and its only consumer is `IdentifierRecords.build_identifier_records/1`, which is
what writes `:mac` identifier rows. A randomized MAC observed passively is simply never
registered as an identity anchor, while a randomized MAC from a virtualization source keeps its
current meaning.

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

## Suppression is in-kernel, and the census dies if it stops working

Suppression lives in the eBPF program and there is deliberately **no userspace
fallback**. A fallback would keep the feature looking healthy while every frame crossed the
ring, which is precisely the cost netprobe's zero-copy design exists to avoid. An add-on that
quietly burns resources costs more trust than the feature is worth.

**It failed once by deviating from the pattern this repo already had.** `l2_should_emit` used
`get()` with flags `0`; `update_flow_table`, in the same program, uses `get_ptr_mut()` +
update-in-place + `insert(..., BPF_ANY)`. Matching the proven pattern fixed it outright:

| | broken (`get()`) | fixed (`get_ptr_mut`) |
| --- | --- | --- |
| Rate | ~38,000/sec | **0.36/sec** |
| CPU | ~40% of a core | **0.0416%** |
| RSS | 335 MB peak | **11.7 MB** |
| journald | 1.15M dropped / 30 s | **0** |

**The failure was silent**, which is why a watchdog exists rather than a fallback. The map held
well-formed entries with correct `bpf_ktime_get_ns` timestamps while every frame was still
emitted; the only outward symptom was journald discarding messages. `CensusWatchdog` shuts the
census down when the sustained rate exceeds 200/sec — a threshold that would require ~12,000
distinct bindings on one broadcast domain, so it cannot be reached by a healthy segment. Flow
attribution is unaffected.

### The hot path

`observe_l2_device` runs on every ingress frame while ~99% are discarded, so the ordering is
deliberate. A discarded frame costs **one 2-byte load and two compares**:

1. read the 2-byte ethertype and return unless ARP or IPv6
2. for IPv6, reject non-NDP on one or two further byte loads
3. only then the `interface_allowlist` lookup (a hash lookup), the 6-byte MAC read, and
   `now_ns()` (a helper call)

Previously all four happened before the frame was known to be interesting.

## The ARP/NDP suppression window: 60 seconds, measured

Set empirically on alma-test01 (AlmaLinux 9.8, kernel 5.14, SELinux Enforcing, `ens18` on a
live /24).

**A first measurement attempt was invalid and is recorded so nobody repeats it.** Counting
observations out of the journal reported 117 in 300 s, an apparently clean 0.39/sec. That was
journald's rate limiter: `RateLimitBurst=10000` per 30 s was discarding ~1.15 million messages
per 30 s, so the true rate was ~38,000/sec. **Any journal-derived measurement here must check
for `Suppressed N messages` before it can be believed.**

**Validated, 600 s, zero journald suppression:**

| Metric | Value |
| --- | --- |
| CPU | **0.0416%** (0.250 CPU-seconds) |
| RSS | 11.7 MB |
| Observations | 217 (**0.36/sec**) |
| Unique MACs / (MAC, IP) pairs | 31 / 48 |
| **Max emissions for any one binding** | **10** |
| Kinds | 124 NDP, 85 ARP request, 8 ARP reply |

**Why this validates 60 s, arithmetically.** Across 600 s a 60 s refresh permits at most
600/60 = 10 emissions per binding. The busiest binding emitted exactly 10. Independently
reproduced over 300 s, where the maximum was exactly 5.

**Headroom.** ~0.0116 observations/sec per device, so ~12/sec at 1,000 devices and ~116/sec at
10,000 — still under the watchdog ceiling, against a ring holding ~21,800 of these 48-byte
records.

**The window does not gate transient visibility.** A first sighting is always emitted; the
window only rate limits refreshes. A device present for 90 s is recorded on arrival.

**What no window value could have fixed.** Before the census was restricted to ARP and NDP,
routed traffic paired the gateway's MAC with an unbounded set of remote addresses, so every new
remote IP minted a fresh key and nothing was ever suppressed. That was a design error, not a
tuning problem.

## Open Questions

- Should `otel_log`/OCSF event emission accompany the inventory path, or is
  `DeviceSourceObservation` alone sufficient for the first cut?
- ~~Should IPv6 NDP be included now?~~ **Resolved: yes, implemented.** ICMPv6 types 133-136,
  including Router Solicitation, which a host emits as it joins the link -- the v6 counterpart
  to gratuitous ARP. NDP was 66 of 117 observations in the live run, i.e. the majority.
