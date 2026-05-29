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

