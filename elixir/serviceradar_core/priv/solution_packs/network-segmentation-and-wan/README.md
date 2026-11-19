# Network Segmentation and WAN Resilience

First-party ServiceRadar Solution Pack (`io.serviceradar.network-segmentation-and-wan`) verifying multi-vantage network segmentation isolation across DMZ and core edge agents alongside WAN DNS resolution latency and answer posture.

## Included Resources

### Declarative Checks (2)
- `multi-vantage-segmentation-isolation` -- Hybrid `decision_table` check combining DMZ and core `tcp_connect` edge probes with a `vantage_point` health signal and a mandatory all-`*` `inconclusive` catch-all rule (`isolated` / `segmentation_breach` / `inconclusive`).
- `wan-dns-resolution-posture` -- Edge `dns_lookup` check measuring `example.com` resolution latency and verifying an expected answer record is returned.

### Stateful Alert Rules (2)
- `network_segmentation_breach` (`enabled`) -- Opens a critical alert when the DMZ vantage point unexpectedly reaches a protected internal service.
- `wan_dns_resolution_degraded` (`paused`) -- Opt-in warning alert triggered when WAN DNS resolution latency enters the degraded threshold.

### Authored Dashboards (1)
- `network-segmentation-and-wan-overview` -- Unified SRQL overview dashboard tracking segmentation isolation checks, WAN DNS probe health, and open resilience alerts.
