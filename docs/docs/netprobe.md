---
sidebar_position: 17
title: Host Network Visibility
---

# Host Network Visibility

Host Network Visibility uses the `serviceradar-netprobe` sidecar to observe
traffic from a ServiceRadar agent host and emit passive device fingerprint
evidence. Phase 1 is limited to passive fingerprinting. DPI, process
attribution, external flow attribution, and remote packet capture are reserved
for later phases.

## Current Scope

Phase 1 installs the sidecar binary at:

```bash
/usr/local/lib/serviceradar/bin/serviceradar-netprobe
```

Debian and RPM agent packages set `cap_net_raw` on that binary during
post-install. Kubernetes deployments keep `agent.netprobe.enabled` defaulted to
`false` so the sidecar can be rolled out deliberately after lab validation.

Until your release has completed the sidecar startup validation, treat
`netprobe` as a lab-only capability. Visibility profiles can be created and
compiled, but production deployments should leave the Helm toggle disabled.

## Requirements

- Linux agent hosts only.
- A ServiceRadar agent package or image that includes
  `serviceradar-netprobe`.
- `cap_net_raw` on the sidecar binary, or `NET_RAW` in the agent pod security
  context for Kubernetes.
- Explicit capture interface allowlist. The sidecar refuses `any`, wildcard
  names, and interfaces outside the allowlist.
- RBAC permission for visibility profiles:
  `visibility_profiles:read`, `visibility_profiles:write`, and
  `visibility_profiles:delete` as appropriate.

## Enabling Profiles

1. Open **Settings > Networks > Discovery > Visibility Profiles**.
2. Create a profile with a descriptive name and an SRQL target query.
3. Set the profile priority. If multiple profiles match a device, the highest
   priority profile wins.
4. Enable the Phase 1 fingerprint protocols you want. TCP and HTTP evidence are
   the initial practical targets; TLS JA4/JA4S extraction is still pending.
5. Set `sample_interval_ms` to control how often a matching IP/protocol pair
   may emit a new sample.
6. Save the profile and confirm the target count is expected.

Example SRQL targets:

```text
in:devices tags.role:database
in:devices hostname:edge-*
in:devices type:Server
```

## Capture Interface Allowlist

Use concrete interface names, such as `eth0`, `ens192`, or `bond0`. Do not use:

- `any`
- wildcard values such as `eth*`
- interface names that do not exist on the agent host

On a Linux host, list interfaces with:

```bash
ip -o link show
```

For a local lab run, a minimal sidecar config looks like:

```json
{
  "enabled": true,
  "capture_interfaces": ["eth0"]
}
```

## Lab Smoke Test

Use this only on a controlled agent host where passive capture is approved.

```bash
sudo getcap /usr/local/lib/serviceradar/bin/serviceradar-netprobe
sudo mkdir -p /run/serviceradar/netprobe
sudo /usr/local/lib/serviceradar/bin/serviceradar-netprobe \
  --socket /run/serviceradar/netprobe/ipc.sock \
  --config /etc/serviceradar/sidecars/netprobe.json \
  --log-format text
```

In another shell, verify the metrics endpoint:

```bash
curl -s http://127.0.0.1:9417/metrics
```

Useful metrics include:

- `netprobe_packets_processed_total`
- `netprobe_packets_dropped_total`
- `netprobe_events_emitted_total{stream="fingerprint"}`
- `netprobe_signature_failures_total`
- `netprobe_uptime_seconds`

## Troubleshooting

### Sidecar missing or not executable

Check the binary and file capabilities:

```bash
ls -l /usr/local/lib/serviceradar/bin/serviceradar-netprobe
sudo getcap /usr/local/lib/serviceradar/bin/serviceradar-netprobe
```

If `cap_net_raw` is missing on a package-based install, rerun:

```bash
sudo setcap cap_net_raw=+ep /usr/local/lib/serviceradar/bin/serviceradar-netprobe
```

### Interface denied

The sidecar rejects `any`, wildcard interfaces, and non-allowlisted names. Use
`ip -o link show`, update the capture allowlist to concrete interface names, and
restart the agent or sidecar.

### No fingerprint events

Confirm:

- The visibility profile is enabled.
- The SRQL target count includes the device.
- The canonical device has an IP address.
- The capture interface sees traffic for that device IP.
- The selected protocol is implemented in the current phase.

### Repeated restarts

The agent sidecar manager probes health every 5 seconds, restarts with
exponential backoff from 1 second up to 60 seconds, and opens the restart
circuit after 5 restarts in a minute. Check the Agent Detail page for the
`netprobe` state and `last_error`, then review agent logs for entries tagged
with `sidecar=netprobe`.

## Privacy

Phase 1 does not perform active probing, TLS interception, or packet payload
retention. It does not store full packets, HTTP URIs, DNS query names, or
decrypted TLS contents.

Phase 1 may emit:

- Source IP bound to a canonical ServiceRadar device.
- TCP passive fingerprint signatures.
- Selected HTTP header fingerprints, limited to `Server`, `User-Agent`, and
  `Accept-Language`.
- Timing and profile metadata needed for provenance and rate limiting.

Later phases add DPI, process attribution, external flow attribution, and remote
packet capture. Those phases must preserve the same privacy posture: no
payload-by-default behavior, explicit profile scoping, and operator-visible
audit/provenance for captured evidence.
