# IPv6 Sweep Scanner Validation Notes

## Scanner Contract Inventory

- `scan.Scanner` is the common execution contract: `Scan(ctx, []models.Target)` returns a result channel and `Stop()` releases runtime resources.
- `scan.StreamingScanner` is the bounded large-sweep contract. The raw SYN scanner implements `ScanStream` so callers can feed targets incrementally instead of materializing every host/port pair.
- `scan.StatsProvider` is currently implemented by the raw SYN scanner. These counters describe raw SYN packet/ring/retry/rate behavior and are exported through sweep completion scanner stats.
- `scan.CapabilityProvider` reports runtime address-family support. ICMP reports available IPv4/IPv6 packet connections, TCP connect reports IPv4/IPv6 support, and raw SYN currently reports IPv4 enabled with IPv6 disabled until live send/capture support lands.

## Shared Logic Reuse

- Target routing lives in the sweeper, not in the scanners. Generated targets carry `address_family`, `requested_sweep_mode`, `effective_sweep_mode`, `scanner_path`, and `ipv6_raw_syn_fallback` metadata so result ingestion can see both requested and actual execution paths.
- TCP connect uses `net.JoinHostPort`, so IPv4 and IPv6 socket formatting stays in the standard library instead of custom string handling.
- Raw SYNv6 packet construction reuses the same TCP header and response-classification contract as IPv4, with IPv6-specific pseudo-header checksum and ICMPv6 error decoding.
- Raw SYN streaming remains scanner-owned. `ScanStream` batches target input and drains result channels between batches to keep large sweeps bounded.
- Scanner stats now carry `protocol`, `address_family`, and `scanner_path` labels so operators can tell which scanner path produced packet/rate counters.

## Runtime Privileges

- Linux raw ICMP and raw SYN paths require `CAP_NET_RAW` or equivalent root privileges.
- Helm defaults keep the agent `hostNetwork: true` and `allowNetRaw: true`; the agent template adds `NET_RAW` when `agent.allowNetRaw` is enabled.
- The Linux package systemd unit grants `AmbientCapabilities=CAP_NET_RAW` and `CapabilityBoundingSet=CAP_NET_RAW` for `serviceradar-agent`.
- The Docker compose agent image intentionally runs as root for raw socket access.
- eBPF capabilities are separate from `NET_RAW`; the Helm chart does not infer BPF/PERFMON/SYS_RESOURCE from raw socket support.

## Manual Validation Path

1. Confirm the agent advertises scanner capabilities in startup/sweep logs:

   ```bash
   journalctl -u serviceradar-agent --since "5 minutes ago" --no-pager \
     | grep -E 'icmpIPv[46]Available|tcpRawSYNIPv[46]Available|tcpConnectIPv[46]Available|scanner_path|address_family'
   ```

2. Validate ICMPv6 loopback through the focused test on a host with IPv6 loopback and raw socket permission:

   ```bash
   go test ./go/pkg/scan -run TestICMPSweeper_IPv6LoopbackScan -count=1
   ```

3. Validate mixed-family target routing without live network dependency:

   ```bash
   go test ./go/pkg/sweeper -run 'TestTargetGeneration_IPv6|TestTargetGenerationMixedFamilyRouteSummary|TestGetScannerStatsLabels' -count=1
   ```

4. For a reachable IPv6 host, create a sweep group with a literal IPv6 target and modes `icmp,tcp`. Until live raw SYNv6 send/capture is enabled, TCP targets should report `scanner_path=tcp_connect_ipv6_raw_syn_fallback`, while ICMP targets should use `scanner_path=icmp`.

5. In Kubernetes, verify the Helm-rendered agent container includes `NET_RAW`:

   ```bash
   helm template serviceradar ./helm/serviceradar -f helm/serviceradar/values-demo.yaml \
     | awk '/name: agent/,/volumeMounts/' \
     | grep -A5 -B2 NET_RAW
   ```

## Remaining Raw SYNv6 Enablement

The current branch has IPv6 SYN packet construction, TCP/ICMPv6 reply classification, target routing, fallback, and diagnostics. It intentionally does not advertise live raw SYNv6 capability yet. Enabling that requires the Linux send socket path and packet capture filter to accept IPv6 traffic end to end, then flipping `RawSYNIPv6` only when that live path is verified.
