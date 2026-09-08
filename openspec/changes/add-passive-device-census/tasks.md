## 1. Prove the observation path (observe-only)

- [x] 1.1 Extract `h_source` from the Ethernet header in the eBPF path and carry it on
      observations (`observe_l2_device` in `rust/netprobe/ebpf/src/lib.rs`)
- [x] 1.2 Verify with `bazel build //rust/netprobe/ebpf:netprobe_ebpf_object` and a userspace
      test asserting a known frame yields the expected MAC
- [x] 1.3 Add `ETH_P_ARP` (0x0806) parsing producing sender-IP / sender-MAC observations
- [x] 1.4 Unit-test ARP parsing against request, reply, gratuitous, and RFC 5227 probe
      records, plus truncated/unknown-version records that must be rejected, not misparsed
- [x] 1.5 **IPv6 NDP** (ICMPv6 133-136, including Router Solicitation -- the v6 counterpart
      to gratuitous ARP). Added at the owner's request.
- [x] 1.6 **Restrict the census to ARP and NDP only.** Measured on alma-test01: observing
      every frame produced ~400 observations/sec from only 41 MACs, because routed traffic
      pairs the gateway's MAC with an unbounded set of remote addresses, so every new remote
      IP became a new suppression key and the cache never suppressed. ARP and NDP are
      link-local, so both the MAC and the address belong to a device on this segment.
- [x] 1.7 **Run the census in attribution-only mode.** netprobe disables packet capture when
      the interface carries the host default route, because AF_XDP/XDP *redirect* would
      black-hole connectivity -- which is every single-NIC host, i.e. exactly the segment
      worth surveying. `netprobe_tc_ingress` only observes and returns `TC_ACT_OK`, so the
      ingress classifier attaches there and nothing else does.
- [x] 1.8 **Detach a stale `netprobe_tc_ingress` before attaching.** Observed on alma-test01:
      three copies attached after three restarts, two from an older build, so measurements
      were partly produced by stale code. Also added `l2_seen` / `l2_observations` to the
      unit's stale-pin cleanup, which did not know about them.
- [x] 1.9 **Bound the poll loop.** The unbounded drain never returned under load, so the
      worker never re-checked its stop flag and `systemctl stop` hung until systemd killed
      the unit on timeout.

## 2. Stop discarding DHCP identity

- [ ] 2.1 Extend `DhcpObservation` in `rust/netprobe/src/dpi/dhcp.rs` to retain `chaddr`,
      Option 12 hostname, and the Option 60 vendor class string
- [ ] 2.2 Keep `option_order` and `parameter_request_list` extraction byte-identical; add a
      regression test proving the existing fingerprint axes are unchanged
- [ ] 2.3 Test DHCPv4 and DHCPv6 paths, including a message with no Option 12 and one with a
      vendor class present but empty

## 3. Randomized-MAC classification (lands BEFORE anything touches identity)

- [x] 3.1 Implement locally-administered detection (bit 1 of the first octet) and mark
      observations accordingly
- [x] 3.2 Test the full boundary: `x2`/`x6`/`xA`/`xE` first octets classify as randomized,
      burned-in vendor OUIs do not, group (broadcast/multicast) sources are rejected outright
- [ ] 3.3 Enforce in reconciliation that a randomized MAC cannot anchor a canonical device,
      cannot merge two devices, and cannot claim an IP
- [ ] 3.4 Test that the same physical device under three randomized MACs does not become three
      devices

## 4. Deliver observations to the inventory

- [ ] 4.1 Emit passive observations from netprobe with a distinct source identity
- [ ] 4.2 Ingest into `DeviceSourceObservation` (`mac`, `ip`, `hostname`, `vendor_name`)
- [ ] 4.3 Bound emission per (MAC, IP) per window so a chatty segment cannot flood ingestion
- [ ] 4.4 Test that an observation matching no device is retained and queryable but mints no
      canonical device
- [ ] 4.5 Test that an observation matching a known device updates last-seen and records the
      passive discovery source

## 5. Measure before enabling

- [x] 5.1 Run observe-only on a real segment (alma-test01, AlmaLinux 9.8, SELinux Enforcing,
      kernel 5.14, interface ens18). First run discovered **40 unique devices in ~2 minutes
      with zero packets transmitted**, including IPv6/NDP observations and correctly flagged
      randomized MACs.
- [x] 5.2 Confirm the transient case: a first sighting is always emitted regardless of the
      refresh window, so a device present for under a minute is recorded on arrival. 29 unique
      devices were observed in a 300s window without any sweep running.
- [x] 5.3 Confirm no traffic is emitted during discovery -- the census only reads frames the
      host already receives; there is no transmit path in the code at all.
- [x] 5.4 **Suppression window decided from measurement: 60 seconds.** Validated run: 230
      observations over 300s (**0.77/sec**) across 29 MACs and 46 (MAC, IP) pairs, with the
      busiest pair emitting exactly 5 times -- the arithmetic maximum for a 60s refresh --
      and 46 x 5 = 230, i.e. every binding emitting exactly at the window cadence. Confirmed
      against the last 120s of steady state (92 observations, again 0.77/sec) with zero
      journald suppression.
      **An earlier reading of 117/300s was invalid**: it measured journald's rate limiter
      (~1.15M messages discarded per 30s), not the census. Any journal-derived measurement
      must check for `Suppressed N messages` first.
- [x] 5.6 **Suppression is in-kernel, with NO userspace fallback.** The first attempt used
      `get()` with flags `0` and suppressed nothing; `update_flow_table` in the same program
      uses `get_ptr_mut()` + update-in-place + `insert(..., BPF_ANY)`, and matching that proven
      pattern fixed it: ~38,000/sec and ~40% of a core became **0.36/sec and 0.0416% CPU**.
      A userspace fallback was written, measured, and then deliberately **removed** -- it would
      have kept the feature looking healthy while every frame crossed the ring, masking exactly
      the failure that must be loud.
- [x] 5.7 **Census shuts itself down if suppression stops working.** The failure was silent:
      well-formed map entries with correct timestamps while every frame was emitted, the only
      symptom being journald discarding ~1.15M messages/30s. `CensusWatchdog` trips above a
      sustained 200 observations/sec -- unreachable on a healthy segment, which would need
      ~12,000 distinct bindings -- logs the cause, and stops the census. Flow attribution is
      unaffected. Four tests, including a 40,000/sec flood.
- [x] 5.8 **Hot path costs one 2-byte load for a discarded frame.** Ethertype is read first;
      the MAC read, the `interface_allowlist` hash lookup and the `bpf_ktime_get_ns` helper
      call are all deferred until the frame is known to be ARP or NDP. Previously all four
      happened on every frame.
- [x] 5.5 Verify shutdown no longer hangs: `systemctl stop` now completes in **0.68s** (it
      previously ran to systemd's kill timeout), and exactly one TC filter is attached after
      restart rather than one more per restart.

## 6. Document the boundaries

- [ ] 6.1 Document that coverage is per broadcast domain, and that off-segment the observer
      sees the router's MAC
- [ ] 6.2 Document active probing as opt-in and off by default, with its transient-device
      failure mode stated

## 7. Full verification

- [ ] 7.1 `make test` green before opening the PR
- [ ] 7.2 `bazel test //rust/netprobe/...` green
