---
sidebar_position: 16.5
title: Visibility Profiles
---

# Visibility Profiles

Visibility Profiles are the control-plane policy for **passive packet
observation**. They tell enrolled agents (and the `netprobe` add-on they
supervise) *which devices* may be fingerprinted, *which host interfaces* may
be captured, and *which packet-level capabilities* (TCP/TLS/HTTP fingerprints,
DPI) are allowed.

They do **not** run network sweeps, and they are **not** what turns on
NetFlow-to-process joins. Sweep Profiles (`/settings/networks`) actively scan
CIDRs. Attributed flows come from assigning the netprobe add-on (see below).
Visibility Profiles watch packets already crossing an allowlisted interface.

## Why they exist

ServiceRadar already discovers devices with sweeps, SNMP, and inventory
imports. Packet-level host observation still fills gaps those paths cannot:

1. **Unknown devices.** Endpoints that do not answer SNMP often land in
   inventory with no OS, vendor, or service evidence. Passive TCP / TLS / HTTP
   fingerprints give the registry something to work with without an active
   probe.
2. **On-site packet captures.** Classifying an unknown protocol used to mean
   driving to the site with Wireshark. Continuous DPI on the agent host is the
   always-on substitute: protocol identity only, no payloads.
3. **Air-gapped / edge networks.** When an engineer *does* need a packet
   capture, the same interface allowlist that gates passive observation also
   gates remote capture sessions. Capture cannot target an interface the
   profile did not name.

A fourth gap -- **which process owned this NetFlow 5-tuple** -- is also
closed by netprobe, but **not by this profile**. It is the add-on's default
eBPF kprobe path. See [Flow attribution does not need a profile](#flow-attribution-does-not-need-a-profile).

The privileged collector is the [netprobe](./netprobe.md) native add-on. The
profile is the policy object operators edit in the UI for capture and
fingerprinting. A profile with no netprobe on the host has nothing to apply
it. Netprobe with no matching profile still emits process attribution; it
just has empty `visibility_config.device_bindings`, so per-device fingerprint,
DPI, and profile-gated capture do not run for that IP.

## Where to find them

**Settings -> Network Services -> Discovery -> Visibility Profiles**
(`/settings/networks/visibility-profiles`)

The page lives next to Sweep Profiles and SNMP Profiles because all three are
fleet-wide targeting policies. Only Visibility Profiles compile into the
agent's `visibility_config` and are consumed by netprobe.

Required permissions:

| Permission | Default roles | Effect |
| --- | --- | --- |
| `visibility_profiles:read` | all roles | View the list and compiled preview |
| `visibility_profiles:write` | operator, admin | Create, edit, enable/disable |
| `visibility_profiles:delete` | admin | Delete a profile |

Creates, updates, disables, and deletes are recorded in AshPaperTrail
(`platform.visibility_profile_versions`) with actor and prior/new values.

## How a profile is applied

```text
Visibility Profile (SRQL target + fingerprint/DPI + interface allowlist)
        |
        v
VisibilityCompiler  --resolves highest-priority matching profile per device-->
        |
        v
AgentConfigResponse.visibility_config  (pushed via agent-gateway)
        |
        v
netprobe ApplyConfig  --packet capture/DPI/fingerprint on allowlisted interfaces-->
        |
        +--> fingerprint events (TCP SYN, TLS ClientHello, HTTP banners)
        +--> DPI classification (protocol only)
        +--> process snapshots (listening sockets)

netprobe add-on enabled=true  (independent of the profile)
        |
        v
host-wide eBPF kprobes --> FlowAttributionEvent --> in:attributed_flows
```

Resolution rules:

- Only **enabled** profiles are considered.
- A blank target query is treated as `in:devices` (every device in the
  partition).
- When two enabled profiles match the same device, the **higher `priority`
  wins**. The loser is not merged; the device gets one binding.
- A device with no matching profile, or no canonical IP, compiles to a
  **disabled** config with empty `device_bindings`. Per-device fingerprint
  and DPI do not run for that IP. Host-wide process attribution from the
  add-on still runs.
- Saving a profile invalidates the `:visibility` config cache so agents pick
  up the change on the next config refresh (typically within a few minutes).

## Creating a profile

1. Open **Visibility Profiles** and click **New Profile**.
2. Set **Name**, optional **Description**, and **Priority** (higher wins on
   overlap).
3. Leave **Enabled** off until targeting and the interface allowlist are
   correct.
4. Set **Sample interval ms** (default `60000`). This is the minimum interval
   per IP/protocol pair. `0` disables rate limiting.
5. Set **Retention days** (default `30`, minimum `1`). This is stored on the
   profile as the intended observation window.
6. Under **Targeting**, write an SRQL query or use **Query Builder**. The
   form shows a live target count when the query is valid.
7. Under **Passive Fingerprinting**, list **Capture interfaces** (one per
   line or comma-separated). An enabled profile **must** name at least one
   interface. `any` and wildcards (`eth*`) are rejected.
8. Enable only the fingerprint axes you need: **TCP**, **TLS**, **HTTP**.
9. Optionally enable **Deep Packet Inspection** and pick protocols. DPI
   records protocol identity only; payloads, URIs, and DNS names are not
   stored.
10. Optionally set a **Process snapshot** interval in seconds (`0` disables
    snapshots). Ignore the **Flow Attribution** checkboxes; they do not
    drive attributed flows (see below).
11. Save. Use the row's code-bracket button to preview the compiled JSON the
    agent would receive.

Start with one canary host, one interface, and TCP fingerprinting only. Turn
on TLS/HTTP and DPI after that host is producing evidence.

## Targeting examples

Blank targeting is equivalent to `in:devices`. Narrower queries keep capture
off hosts that should not be observed:

```text
in:devices
in:devices tags.role:server
in:devices hostname:edge-*
in:devices type:Server AND tags.environment:production
```

The Query Builder edits the same `target_query` string. If you type SRQL by
hand and then open the builder, click **Apply** when the two are out of
sync.

Imported devices (Armis, NetBox, UniFi, and so on) receive a binding when
they match the query, the same as sweep-discovered hosts.

## Profile settings

| Setting | Default | What it controls |
| --- | --- | --- |
| `name` | required | Unique within the partition |
| `description` | empty | Operator notes |
| `enabled` | `true` | Whether the compiler may emit a binding |
| `target_query` | `in:devices` when blank | SRQL device selector |
| `priority` | `0` | Higher value wins on overlap |
| `capture_interfaces` | `[]` | Host NICs netprobe may attach to. Required when enabled. No `any` or `*` |
| `sample_interval_ms` | `60000` | Minimum sample interval per IP/protocol pair. `0` = no rate limit |
| `retention_days` | `30` | Intended observation retention on the profile (minimum 1) |
| `fingerprint.tcp` | `true` | Passive TCP SYN fingerprints (p0f / MuonFP / Satori TCP) |
| `fingerprint.tls` | `true` | TLS ClientHello fingerprints (JA4 base) |
| `fingerprint.http` | `true` | HTTP banner / Recog / Satori HTTP evidence |
| `dpi.enabled` | `false` | Master switch for protocol classification |
| `dpi.protocols` | `[]` | `http1`, `http2`, `tls`, `dns`, `ssh`, `ftp`, `quic`, `mqtt`, `bittorrent` |
| `flow_attribution.tcp/udp/quic` | `false` | Stored on the profile only. Not compiled onto the agent wire (`flow_attribution` is reserved in `VisibilityConfig`). NetFlow-to-PID joins are the netprobe add-on, not this toggle. |
| `process_snapshot_interval_s` | `0` | Seconds between listening-socket snapshots. `0` disables. Prefer the add-on field of the same name. |

Compiled agent config looks like:

```json
{
  "enabled": true,
  "capture_interfaces": ["eth0"],
  "device_bindings": [
    {
      "ip": "192.0.2.10",
      "profile_id": "...",
      "profile_name": "Edge servers",
      "fingerprint": {"tcp": true, "tls": true, "http": false},
      "dpi": {"enabled": false, "protocols": []},
      "sample_interval_ms": 60000
    }
  ],
  "dpi": {"enabled": false, "protocols": []},
  "flow_attribution": {"tcp": true, "udp": false, "quic": false},
  "process_snapshot_interval_s": 0,
  "default_sample_interval_ms": 60000
}
```

A device that matches no profile compiles to `"enabled": false` and
`"device_bindings": []`.

## What to turn on, and when

| Capability | Use it when | Leave it off when |
| --- | --- | --- |
| TCP fingerprint | Inventory is full of type-unknown hosts | The host sees no TCP handshakes you care about |
| TLS / HTTP fingerprint | You need service/OS corroboration beyond SYN | Policy forbids even metadata from those protocols |
| DPI | You need protocol identity (TLS vs SSH vs QUIC) | Fingerprints alone are enough; keep the surface small |
| Process snapshots | You want a periodic listen-table for the host | Event-driven attribution already covers the questions you have |

Do not use the profile **Flow Attribution** checkboxes to turn attributed
flows on or off. That switch is the netprobe add-on `enabled` flag.

## Flow attribution does not need a profile

`in:attributed_flows` can be populated with **zero** Visibility Profiles.

Netprobe attaches global socket-lifecycle kprobes (`tcp_connect`,
`inet_csk_accept`, and related) whenever the add-on is assigned and
`enabled: true`. Those probes are not bound to `capture_interfaces`. An
empty interface list is an explicit **attribution-only** mode: process
identity still flows, packet capture / DPI / fingerprinting do not.

The path is:

```text
netprobe eBPF kprobes (host-wide)
  -> FlowAttributionEvent (agent IPC)
  -> agent-gateway source=flow-attribution
  -> core join with NetFlow
  -> in:attributed_flows
```

The operator control for that path is **Settings -> Agents -> Add-ons**
(netprobe assignment, `enabled`, `emit_raw_flow_attribution_events`). Schema
default for raw events is `true`. `ParseVisibilityConfig` also defaults
those IPC flags on even when no profile compiled a binding.

The Visibility Profile form still shows TCP/UDP/QUIC flow-attribution
toggles because the Ash resource kept the original unified-profile fields.
Those values are not present on `monitoring.VisibilityConfig` or
`VisibilityAgentConfig` (the proto field is reserved). Toggling them does
not start or stop attributed flows.

If attributed flows are missing, check netprobe assignment and
`in:addon_statuses addon_id:netprobe`, not this Settings page. See
[Host Network Visibility](./netprobe.md).

DPI copy in the form is the privacy contract: **protocol detection only**.
Payloads, URIs, and DNS query names are not stored even when the matching
dissector runs.

The fingerprint ensemble itself (p0f, MuonFP, JA4 base, HASSH, Recog,
Satori) is documented in [Fingerprint Architecture](./fingerprint-architecture.md).
The profile only enables or disables the observation axes those matchers
consume.

## Rollout checklist

Visibility Profiles and netprobe have to land together:

1. Install and assign the **netprobe** add-on to the host agent. See
   [Host Network Visibility](./netprobe.md).
2. Confirm the host NIC name (`ip -o link show`) and put that exact name in
   `capture_interfaces`.
3. Create a **disabled** profile targeting one canary device, with TCP
   fingerprinting only.
4. Enable the profile. Wait for the agent config refresh, or restart the
   agent if you need it immediately.
5. Confirm `serviceradar-netprobe.service` is active and
   `in:addon_statuses addon_id:netprobe` is fresh for that agent.
6. Look for fingerprint evidence on the device. Attributed flows should
   already be present from the add-on assignment even before this profile
   is enabled.
7. Widen targeting and capabilities only after the canary looks right.

Do not enable a profile against `in:devices` on day one. A blank target plus
an enabled toggle is a fleet-wide capture policy.

## Visibility Profiles vs related settings

| Surface | Path | Job |
| --- | --- | --- |
| **Visibility Profiles** | `/settings/networks/visibility-profiles` | Policy: who, which NIC, fingerprint/DPI capture |
| **netprobe add-on** | **Settings -> Agents -> Add-ons** | Collector. `enabled` turns on host-wide process attribution; capture/DPI need a profile (or add-on advanced fields) |
| **Sweep Profiles** | `/settings/networks` | Active CIDR/port scans; optional banner grab |
| **Sysmon Profiles** | `/settings/sysmon` | Host CPU, memory, disk, interface, and process *metrics* |
| **SNMP Profiles** | `/settings/snmp` | Polled SNMP metrics and trap handling |

Sysmon process metrics and visibility process snapshots are not the same
thing. Sysmon samples `top`-style CPU/memory. Visibility snapshots record
listening sockets with redacted process context so operators can see what
the host is offering on the network.

## Troubleshooting

### Profile saved, nothing captured

1. Confirm the profile is **Enabled** and lists a real interface name, not
   `any`.
2. Confirm the target query matches the device. Blank targeting is
   `in:devices`; a typo in SRQL matches nobody. The form's target count is
   the first check.
3. If another enabled profile also matches, the higher **priority** wins.
   The UI does not merge capabilities.
4. Confirm netprobe is assigned and `serviceradar-netprobe.service` is
   running on the host that owns the NIC.
5. Confirm the device has a canonical IP. The compiler omits bindings for
   devices with no IP.

### Config changes not showing up on the agent

Agents refresh pushed config on a jittered interval (on the order of a few
minutes). Saving a profile invalidates the visibility cache, but the agent
still has to pull. Restart the agent to force a refresh.

### Interface rejected

Enabled profiles must include at least one allowlisted interface, and the
name cannot be `any` or contain `*`. Use the kernel name (`eth0`, `ens192`,
`enp1s0`), not an alias you wish existed.

### DPI / TLS / HTTP enabled, no evidence

Those axes need payload on the allowlisted interface. A host that only
routes traffic it does not terminate may still produce TCP SYN fingerprints
from the kprobe path, but JA4 / HTTP / DPI need the corresponding bytes.
See [Fingerprint Architecture](./fingerprint-architecture.md).

### Flow attribution empty

This is not a Visibility Profile problem. Confirm netprobe is assigned with
`enabled: true`, `serviceradar-netprobe.service` is running, and
`in:addon_statuses addon_id:netprobe` is fresh. Then query
`in:attributed_flows`. Joins with switch NetFlow are a central pipeline;
see [Host Network Visibility](./netprobe.md).

## Related documentation

- [Host Network Visibility](./netprobe.md) - installing and operating the
  collector
- [Fingerprint Architecture](./fingerprint-architecture.md) - corpora,
  licenses, and matchers
- [Sysmon Profiles](./sysmon-profiles.md) - host health metrics
- [Network Sweeps](./network-sweeps.md) - active discovery
- [Cloud Quickstart](./cloud-quickstart.md#82-visibility-profiles-passive-fingerprint--capture) -
  first-run steps
- [Roles & Permissions](./rbac-and-roles.md) - `visibility_profiles:*`
