---
sidebar_position: 3
title: Akamai CDN and Server-Timing Integration
---

# Akamai CDN and Server-Timing Integration

ServiceRadar parses W3C `Server-Timing` metrics and Akamai EdgeScape headers
into first-class typed columns on `RumBeaconV1` and scalar metrics on
`metrics.rum.>`. This populates the **Edge vs Origin RTT vs Browser Render**
and **Akamai CDN Cache Status & Edge Latency** panels on the **Web RUM**
dashboard without regex or JSON extraction.

## 1. Front your website with Akamai Delivery (Property Manager)

In Akamai Control Center for each website property (for example
`shop.example.com`):

1. **Origin Server**: Point the Akamai property to your Kubernetes Envoy
   Gateway or origin hostname.
2. **Emit W3C `Server-Timing` headers**: Configure Property Manager (via
   **Modify Outgoing Response Header** or EdgeWorkers) to emit Akamai's
   `Server-Timing` header on document responses:

   ```http
   Server-Timing: cdn-cache; desc=HIT, edge; dur=12, origin; dur=45, ak_p; desc=iad-01
   ```

   ServiceRadar's Rust RUM collector (`rust/otel/src/rum/scrub.rs`) extracts
   these entries automatically:

   | `Server-Timing` Entry | Stored Beacon Column | Scalar Metric (`metrics.rum.>`) |
   |---|---|---|
   | `cdn-cache; desc=HIT\|MISS\|REVALIDATED` | `cdn_cache_status` | -- |
   | `edge; dur=<ms>` | `cdn_edge_rtt_ms` | `rum.akamai_edge_rtt_ms` |
   | `origin; dur=<ms>` | `cdn_origin_rtt_ms` | `rum.akamai_origin_rtt_ms` |
   | `ak_p; desc=<pop>` or `cdn-pop; desc=<pop>` | `cdn_pop` (sets `cdn_provider = "akamai"`) | -- |

   If cross-origin subresources also emit `Server-Timing` that you want visible
   to Boomerang, add:

   ```http
   Timing-Allow-Origin: https://shop.example.com
   ```

3. **Caching**: Cache fingerprinted static assets (`/assets/*`, `/images/*`)
   aggressively at the edge and pass through or short-cache HTML pages so you
   observe both `HIT` and `MISS` origin RTT splits.
4. **DNS & TLS**: Point the site's DNS record to your Akamai Edge Hostname
   (`*.edgekey.net` / `*.edgesuite.net`) with TLS provisioned via Akamai CPS.

## 2. Optional: Front `/rum/v1/beacon` with Akamai for EdgeScape Geo/ASN

Even if `/rum/v1/beacon` is served directly from your cluster's Envoy Gateway,
you receive full Core Web Vitals and website `Server-Timing` metrics (Edge RTT,
Origin RTT, Cache HIT/MISS, POP).

If you also front your beacon hostname (`rum.example.com`) with Akamai:

1. Enable **True Client IP** (`True-Client-IP` / `X-Forwarded-For`) and
   **EdgeScape** (`Akamai-Edgescape` carrying `country_code`, `region_code`,
   `city`, `asnum`, `network`) in Property Manager.
2. Configure `logCollector.otlp.rum.trustedProxies` and
   `logCollector.otlp.rum.cdnPeers` in Helm values so the collector trusts
   `Akamai-Edgescape` only from your gateway and Akamai edge CIDRs:

   ```yaml
   logCollector:
     otlp:
       rum:
         enabled: true
         trustedProxies:
           - "10.0.0.0/8"
           - "172.16.0.0/12"
         cdnPeers:
           - "198.51.100.0/24"
   ```

   Spoofed `Akamai-Edgescape` and `X-Forwarded-For` headers from untrusted
   peers are ignored by default.

## 3. Correlate branch offices and synthetic checks

- **Branch WAN correlation (`prefix_tags`)**: Register corporate egress CIDRs
  in [Prefix Tags](./prefix-tags.md) (for example `198.51.100.0/24` tagged
  `site:branch-01`). The collector matches each beacon's client IP against
  `prefix_tags` in memory **before** IP truncation, letting you filter **Web
  RUM** by branch office and compare against `mtr` and `netperf` telemetry.
- **Active HTTP and TLS posture**: Install the built-in
  `io.serviceradar.http-api-and-tls-posture` Solution Pack targeting your
  website URL (`api_target_url`) and hostname (`tls_target_host`) to track
  synthetic latency and TLS leaf certificate expiry alongside passive RUM
  beacons.
