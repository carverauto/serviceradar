## 1. Prove the observation path (observe-only)

- [ ] 1.1 Extract `h_source` from the Ethernet header in the eBPF path and carry it on
      observations netprobe already produces (`rust/netprobe/ebpf/src/lib.rs`, currently
      dispatching only `ETH_P_IP` 0x0800 / `ETH_P_IPV6` 0x86dd at `:1489-1490`)
- [ ] 1.2 Verify with `bazel build //rust/netprobe/ebpf:netprobe_ebpf_object` and a userspace
      test asserting a known frame yields the expected MAC
- [ ] 1.3 Add `ETH_P_ARP` (0x0806) parsing producing sender-IP / sender-MAC observations
- [ ] 1.4 Unit-test ARP parsing against captured request, reply, gratuitous, and RFC 5227
      probe frames, including a malformed frame that must not panic the parser

## 2. Stop discarding DHCP identity

- [ ] 2.1 Extend `DhcpObservation` in `rust/netprobe/src/dpi/dhcp.rs` to retain `chaddr`,
      Option 12 hostname, and the Option 60 vendor class string
- [ ] 2.2 Keep `option_order` and `parameter_request_list` extraction byte-identical; add a
      regression test proving the existing fingerprint axes are unchanged
- [ ] 2.3 Test DHCPv4 and DHCPv6 paths, including a message with no Option 12 and one with a
      vendor class present but empty

## 3. Randomized-MAC classification (lands BEFORE anything touches identity)

- [ ] 3.1 Implement locally-administered detection (bit 1 of the first octet) and mark
      observations accordingly
- [ ] 3.2 Test the full boundary: `x2`/`x6`/`xA`/`xE` first octets classify as randomized,
      burned-in vendor OUIs do not, broadcast and multicast MACs are handled explicitly
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

- [ ] 5.1 Run observe-only on a real segment; record observation volume, unique MAC count, and
      the randomized-MAC ratio
- [ ] 5.2 Confirm the transient case end to end: a device present for under a minute appears in
      the census with no sweep involved
- [ ] 5.3 Confirm no traffic is emitted during discovery (packet capture on the observer)
- [ ] 5.4 Decide the suppression window from measured volume, not estimate

## 6. Document the boundaries

- [ ] 6.1 Document that coverage is per broadcast domain, and that off-segment the observer
      sees the router's MAC
- [ ] 6.2 Document active probing as opt-in and off by default, with its transient-device
      failure mode stated

## 7. Full verification

- [ ] 7.1 `make test` green before opening the PR
- [ ] 7.2 `bazel test //rust/netprobe/...` green
