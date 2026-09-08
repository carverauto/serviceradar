# Change: Passive L2 device census — see every device on the segment, including transient ones

## Why

Scheduled sweeps only find devices that are present when the sweep runs. A phone that joins
wifi for ninety seconds, a contractor's laptop, an IoT sensor that wakes hourly — none of them
reliably appear. The gap is not scan coverage, it is that scanning is the wrong mechanism:
these devices announce themselves the moment they join, and nothing is listening.

Two signals fire at join time, on every IPv4 device, without being asked:

- **ARP** — RFC 5227 duplicate-address probes and gratuitous ARP. Universal. A printer that
  speaks nothing else still ARPs.
- **DHCP** — carries the client MAC in `chaddr`, the hostname in Option 12, and a vendor class
  string in Option 60.

netprobe is already positioned to see both. It attaches XDP and TC classifiers, holds
`CAP_NET_RAW`, `CAP_NET_ADMIN`, `CAP_BPF` and `CAP_PERFMON`, and already parses DHCPv4/DHCPv6
in `rust/netprobe/src/dpi/dhcp.rs`. Three things stop it being a device census today:

1. **The L2 header is never read.** The eBPF path handles `ETH_P_IP` (0x0800) and `ETH_P_IPV6`
   (0x86dd) only (`rust/netprobe/ebpf/src/lib.rs:26-27`, dispatch at `:1489-1490`), and
   `h_source` — the sender's MAC, present on every single frame — is never extracted.
2. **ARP is dropped.** `ETH_P_ARP` (0x0806) matches no branch, so the most universal join-time
   signal is discarded before parsing.
3. **DHCP identity fields are discarded.** `DhcpObservation` keeps `option_order`,
   `parameter_request_list` and a `vendor_class_present` boolean — fingerprint axes only. The
   MAC (`chaddr`), hostname (Option 12) and the vendor class *string* (Option 60) are parsed
   past and thrown away.

Nothing netprobe observes reaches the device inventory: there is no netprobe →
`DeviceSourceObservation` path at all today.

`DeviceSourceObservation` already carries `mac`, `hostname`, `ip`, `vendor_name`, `model` and
`device_type`, so the landing zone needs no schema change.

## What Changes

- Read `h_source` from the Ethernet header on frames netprobe already parses, so every
  observation carries the sender's MAC.
- Parse `ETH_P_ARP` (0x0806) to capture IP↔MAC bindings at join time, from devices that emit
  no other traffic.
- Stop discarding DHCP identity fields: retain `chaddr`, Option 12 hostname, and the Option 60
  vendor class string alongside the existing fingerprint axes.
- Emit passive device observations from netprobe into `DeviceSourceObservation`
  (`mac`, `ip`, `hostname`, `vendor_name`), establishing the missing netprobe → inventory path.
- **Treat a randomized MAC as provisional identity, never as hardware identity** (see below).
- Make active probing an explicit, off-by-default operator choice. The census is passive.

**Not in scope:** device *type* classification. The Satori corpus and DHCP fingerprint axes
stay where they are and are not extended here — this change is about seeing every device and
binding IP to MAC, not about labelling what each one is. mDNS service/model enrichment
(#3848) layers on top of this later.

## The MAC randomization problem

This is the part that can do damage if it is got wrong, so it is a first-class requirement
rather than a caveat.

iOS and Android rotate their MAC per SSID and re-randomize periodically. Device identity
reconciliation currently treats a distinct MAC as distinct hardware. A passive census feeds
that model exactly the input that breaks it — at far higher volume than any sweep — and the
failure mode is a flood of phantom devices, one per rotation, which is the anchorless-device
and IP-squatting problem already seen in production.

Locally administered MACs are detectable: bit 1 of the first octet (`x2`, `x6`, `xA`, `xE`)
marks a locally administered address, which is what every randomizing implementation sets.
The census SHALL classify these on sight and SHALL NOT let them anchor a canonical device or
merge two devices.

## Impact

- Affected specs: `network-discovery` (new passive census requirements),
  `device-identity-reconciliation` (randomized-MAC handling)
- Affected code: `rust/netprobe/ebpf/src/lib.rs`, `rust/netprobe/src/dpi/dhcp.rs`,
  netprobe's IPC/emit path, and a new observation route into
  `elixir/serviceradar_core/lib/serviceradar/inventory/`
- Affected operations: coverage is per-broadcast-domain. Complete visibility needs netprobe on
  each segment; off-segment the observer sees the gateway's MAC, not the device's. This is a
  deployment consequence, documented rather than solved here.
