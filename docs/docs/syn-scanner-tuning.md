---
sidebar_position: 7
title: SYN Scanner Tuning and Conntrack Mitigation
---

This guide helps you run fast TCP SYN scans safely by controlling scanner rate and, where possible, tuning upstream devices to avoid connection tracking overload.

When to use this:
- You see upstream router/firewall conntrack table exhaustion during scans.
- You want to keep scans fast by exempting scanner traffic from connection tracking.

Scanner-side controls
- tcp_settings.rate_limit: Global packets-per-second cap for SYN packets. Start conservative (e.g., 5,000 pps) and increase while monitoring.
- tcp_settings.rate_limit_burst: Optional burst size. Defaults to rate_limit if omitted.

Upstream device tuning (Linux netfilter)
- Prefer NOTRACK for scanner traffic so SYNs don’t enter conntrack:
  - nftables (recommended):
    - Create raw table chains with low priority (pre-routing/output):
      - `nft add table inet raw`
      - `nft add chain inet raw prerouting { type filter hook prerouting priority -300; }`
      - `nft add chain inet raw output { type route hook output priority -300; }`
    - Exempt scanner host (replace 192.0.2.10):
      - `nft add rule inet raw output ip saddr 192.0.2.10 tcp flags syn / syn notrack`
      - `nft add rule inet raw prerouting ip daddr 192.0.2.10 tcp flags syn / syn notrack`
  - iptables (legacy):
    - `iptables -t raw -A OUTPUT -p tcp --syn -s 192.0.2.10 -j NOTRACK`
    - `iptables -t raw -A PREROUTING -p tcp --syn -d 192.0.2.10 -j NOTRACK`
- If NOTRACK isn’t possible, increase and tune conntrack capacity and timeouts:
  - Capacity:
    - `sysctl -w net.netfilter.nf_conntrack_max=524288` (adjust to device memory)
    - For older kernels: set `nf_conntrack_hashsize` accordingly (often via boot param or module option).
  - Timeouts for half-open/unestablished flows (lower is safer under scan):
    - `sysctl -w net.netfilter.nf_conntrack_tcp_timeout_syn_sent=30`
    - `sysctl -w net.netfilter.nf_conntrack_tcp_timeout_syn_recv=30`
    - `sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=15`
    - Generic: `sysctl -w net.netfilter.nf_conntrack_generic_timeout=60`
  - Persist changes via your distro’s sysctl config.

Other platforms (high level)
- Cisco/ASA: Consider disabling inspection/conntrack for the scanner source IP or placing it in a bypass ACL/policy. Watch “embryonic connection” thresholds.
- Juniper: Use firewall filters or security policies to avoid session creation for scanner source; adjust session table sizes and syn-proxy thresholds if applicable.
- Cloud firewalls/LBs: Use security group rules to bypass state where possible, or keep scanner rate low.

Operational guidance
- Start with scanner `rate_limit` low (e.g., 3–5k pps). Monitor router conntrack utilization and CPU.
- Increase in small steps; ensure half-open/embryonic counts remain stable.
- Prefer per-source-IP NOTRACK/BYPASS so normal traffic remains protected by conntrack.
- Consider segmenting scanning from production NAT/firewall devices when feasible.

Related agent settings
- tcp_settings.max_batch: Larger batches improve efficiency but can amplify bursts.
- tcp_settings.concurrency: High concurrency speeds things up but increases the number of in-flight ports. Balance with `rate_limit` to avoid local source-port pressure and upstream state.

Troubleshooting checklist
- Conntrack drops grow during scans: lower `rate_limit` and reduce timeouts for SYN-SENT/SYN-RECV.
- Router CPU spikes: use NOTRACK for scanner IP; cut `rate_limit`.
- Local port exhaustion logs: reduce `concurrency` or `rate_limit`, or increase timeout; ensure ephemeral port range isn’t overlapping.

