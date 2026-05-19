# IPv6 Sweep Scanner Validation Notes

## Scanner Contract Inventory

- `scan.Scanner` is the common execution contract: `Scan(ctx, []models.Target)` returns a result channel and `Stop()` releases runtime resources.
- `scan.StreamingScanner` is the bounded large-sweep contract. The raw SYN scanner implements `ScanStream` so callers can feed targets incrementally instead of materializing every host/port pair.
- `scan.StatsProvider` is currently implemented by the raw SYN scanner. These counters describe raw SYN packet/ring/retry/rate behavior and are exported through sweep completion scanner stats.
- `scan.CapabilityProvider` reports runtime address-family support. ICMP reports available IPv4/IPv6 packet connections, TCP connect reports IPv4/IPv6 support, and raw SYN reports IPv6 only when the agent has a raw IPv6 send socket plus a usable local IPv6 source address on the scanner interface.

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

4. For a reachable IPv6 host, create a sweep group with a literal IPv6 target and modes `icmp,tcp`. On an agent with `tcpRawSYNIPv6Available=true`, TCP targets should report `scanner_path=tcp`. On an agent without a usable raw SYNv6 path, TCP targets should report `scanner_path=tcp_connect_ipv6_raw_syn_fallback`, while ICMP targets should use `scanner_path=icmp`.

5. In Kubernetes, verify the Helm-rendered agent container includes `NET_RAW`:

   ```bash
   helm template serviceradar ./helm/serviceradar -f helm/serviceradar/values-demo.yaml \
     | awk '/name: agent/,/volumeMounts/' \
     | grep -A5 -B2 NET_RAW
   ```

## Raw SYNv6 Enablement

The raw SYN scanner opens an IPv6 raw send socket when the platform permits it, selects a non-link-local IPv6 source address from the scanner interface, and attaches an AF_PACKET filter that admits IPv4 TCP replies plus IPv6 TCP/ICMPv6 traffic for that local IPv6 address. `RawSYNIPv6` is advertised only when all of those runtime prerequisites are present; otherwise IPv6 TCP targets continue to use TCP connect fallback.
