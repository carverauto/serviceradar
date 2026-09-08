---
sidebar_position: 15
title: Sweep Banner Grab Runbook
---

# Sweep Banner Grab Runbook

Sweep banner grab is an optional active fingerprint phase for network sweeps.
It runs after the SYN scan has identified live, open endpoints, then performs
bounded TCP connects to configured ports and sends successful banners to
netprobe for Recog-style matching. Use it when passive fingerprinting is not
enough to identify server products, OS families, or service versions.

## When to Enable

Enable banner grab on targeted scanner profiles when you need one of these
outcomes:

- Confirm product and version labels for critical services.
- Add active OS evidence for devices that do not produce useful passive traffic.
- Validate inventory labels for infrastructure refreshes, segmentation projects,
  or vulnerability-response scoping.

Keep it disabled in broad default profiles unless operators have reviewed the
expected connection volume. The default is `banner_grab.enabled = false`, which
produces zero outbound banner-grab traffic.

## Recommended Port Allowlists

Start with small, role-specific allowlists:

| Environment | Protocols | Ports |
| --- | --- | --- |
| Linux and network infrastructure | SSH | `22` |
| Windows endpoints | RDP, SMB | `3389`, `139`, `445` |
| Web edge | HTTP | `80`, `8080`, `8000`, `8008` |
| Mail infrastructure | SMTP | `25`, `587` |
| Legacy management | FTP, Telnet | `21`, `23` |
| DNS appliances | DNS | `53` |

Do not add HTTPS as an active banner protocol. TLS evidence comes from the
passive fingerprint pipeline, where ClientHello and ServerHello metadata can be
observed without actively decrypting or requesting application content.

## Traffic and Runtime Estimates

Banner grab only connects to SYN-confirmed open endpoints from the preceding
sweep. It does not materialize a full inventory worklist. The effective probe
count is:

```text
eligible open endpoints = live hosts with matching open ports and no fresh skip
```

Worst-case elapsed time is bounded by:

```text
ceil(eligible open endpoints / max_global_concurrency) *
  (connect_timeout_ms + read_timeout_ms)
```

With the default 256 global concurrency and 2000 ms connect plus 2000 ms read
timeouts:

| Inventory | 1 eligible port per host | 5 eligible ports per host |
| --- | ---: | ---: |
| 20k hosts | about 5 minutes | about 26 minutes |
| 50k hosts | about 13 minutes | about 65 minutes |
| 100k hosts | about 26 minutes | about 2 hours 10 minutes |
| 1M hosts | about 4 hours 20 minutes | about 21 hours 40 minutes |

If `max_probe_rate_per_second` is set, the rate cap becomes the limiting factor.
For example, 100k eligible endpoints at 1000 probes/sec takes at least 100
seconds even if concurrency could go faster.

## IDS and IPS Guidance

Banner grab creates real TCP connections from the ServiceRadar agent source IP.
Before enabling it broadly:

- Add the agent source IPs to approved scanner allowlists.
- Notify SOC teams that connections will follow configured sweep schedules.
- Keep port lists narrow and tied to known service roles.
- Use `min_reprobe_interval_s` to avoid repeatedly probing recently observed
  endpoints.
- Watch connection reset, timeout, and error counters during the first rollout.

## Tuning Controls

Use these profile fields to bound blast radius:

- `max_global_concurrency`: caps active sockets across the phase.
- `max_concurrency_per_host`: caps concurrent connects to one host.
- `per_host_rate_limit_ms`: adds a floor between connects to the same host.
- `max_probe_rate_per_second`: optional global start-rate cap.
- `max_candidate_queue`: bounds queued eligible endpoints.
- `match_batch_size` and `match_batch_max_bytes`: bound netprobe IPC batches.
- `min_reprobe_interval_s`: skips fresh endpoints until the interval expires.

For very large inventories, tune `max_global_concurrency` and
`max_probe_rate_per_second` together. Raising concurrency without raising the
rate cap will not improve runtime, and raising both may require firewall and IDS
coordination.

## Capability Troubleshooting

Agents advertise `sweep.banner_grab` as available only when all prerequisites
are satisfied. Common unavailable reasons:

| Reason | Action |
| --- | --- |
| No enabled profile | Enable banner grab on at least one sweep profile. |
| Netprobe unavailable | Check the netprobe sidecar process and UDS health. |
| Recog corpus missing | Verify the netprobe corpus bundle is present and loaded. |
| Permission denied | Confirm the operator has `networks.sweeps.banner_grab`. |

During a sweep, monitor these counters on the agent metrics endpoint:

- `sweep_banner_grab_candidates_total`
- `sweep_banner_grab_probes_total`
- `sweep_banner_grab_inflight`
- `sweep_banner_grab_queue_depth`
- `sweep_banner_grab_matches_total`
- `sweep_banner_grab_empty_response_total`
- `sweep_banner_grab_connection_reset_total`
- `sweep_banner_grab_timeout_total`
- `sweep_banner_grab_errors_total`
- `sweep_banner_grab_bytes_received_total`

When a banner-grab phase completes, ServiceRadar records an AshPaperTrail audit
entry on the parent sweep execution with summarized probe counts, match counts,
error counts, and total bytes received.

## Opt-Out Procedure

To stop active banner-grab traffic:

1. Open Settings > Networks > Scanner Profiles.
2. Edit every profile that has Banner grab enabled.
3. Turn off the Banner grab toggle and save.
4. Confirm the next agent status push reports `sweep.banner_grab` unavailable
   because no profile requires it.
5. Leave passive fingerprinting enabled if TLS, HTTP, or TCP fingerprint evidence
   is still required.

## Data Handling

Active banner-grab is designed so raw payload bytes never leave the agent host,
and so the canonical Device record only gains structured, matched labels.
Operators reviewing privacy or compliance posture should know:

- **Raw banner bytes stay agent-local.** Every captured banner is forwarded to
  the netprobe sidecar over the host's Unix domain socket
  (`/var/run/serviceradar/netprobe.sock` by default). The bytes are never
  serialised onto the agent's gRPC status push to core and are never written to
  disk.
- **Only matched labels reach core.** After netprobe runs the Recog corpus
  against a banner, only the structured match (corpus label, product, version,
  optional OS family / vendor / CPE) is bridged into the agent's status push
  as a `FingerprintEvent` with `source = sweep_active`. The originating raw
  banner bytes are dropped at the netprobe boundary.
- **Audit summary is counts only.** The AshPaperTrail entry on the parent
  sweep-job record summarises the phase as counts (probes, matches, empty
  responses, errors, total bytes received). It does not include per-probe
  payloads or per-host detail.
- **cmdline and hostname are NOT in the active-fingerprint flow.** Active
  banner-grab fingerprints derive solely from on-wire banner payloads. Process
  cmdline arguments and OS hostnames remain in the passive / host-agent
  evidence stream and are not collected, attached to, or correlated with
  `FingerprintEvent`s emitted by the active sweep path.

If you need to expose the raw banner bytes for a specific Device Detail view,
that requires the operator-only `metadata.raw_banner` privacy opt-in flag
described in §33.18 of the host-network-visibility change proposal; without it,
even operators only see the matched labels.

### Synthetic 1M-Host Validation

The bounded-concurrency invariants advertised above are guarded by
`TestEngineKeepsMillionHostSyntheticStreamBounded` in
`go/pkg/scan/banner_grab/engine_test.go`. The test is opt-in (it skips unless
`SERVICERADAR_LARGE_BANNER_GRAB_TEST=1` is set). To run it locally:

```sh
SERVICERADAR_LARGE_BANNER_GRAB_TEST=1 \
  go test -count=1 -timeout=5m \
  -run TestEngineKeepsMillionHostSyntheticStreamBounded \
  ./go/pkg/scan/banner_grab/...
```

