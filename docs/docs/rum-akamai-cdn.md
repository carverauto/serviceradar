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

## 3. Correlate branch offices, remote vantage points, and `netperf`

Combining passive browser RUM with active edge probes answers whether slow
page loads come from your CDN/origin or from a branch office WAN link.

### A. Tag branch and site egress CIDRs (`prefix_tags`)

1. Open **Settings -> Networks -> Prefix Tags** (`/settings/networks/prefix-tags`).
2. Add each branch or campus public egress CIDR with a consistent site tag
   (for example `198.51.100.0/24` -> `site:branch-01`, `203.0.113.0/24` ->
   `site:hq-west`).
3. The Rust RUM collector matches every incoming beacon's client IP against
   `prefix_tags` in memory **before** IP truncation and stamps `prefix_tag` on
   the stored beacon. Click any `prefix_tag` row in **Dashboards -> Web RUM**
   to isolate that site's Core Web Vitals.

### B. External L7 HTTP/TLS + MTR vantage points (no inbound ports)

Rather than exposing bandwidth test ports to the public internet, deploy an
outbound-only `serviceradar-agent` on an external VPS (such as an Akamai
Linode instance in a remote region):

1. Enroll the agent via **Settings -> Agents -> Deploy** so it dials outbound
   mTLS to your `agent-gateway` (`50052/TCP`) with zero inbound ports required.
2. Open **Solution Packs Catalog** (`/catalog`) and install
   **HTTP API & TLS Certificate Posture** (`io.serviceradar.http-api-and-tls-posture`)
   targeting your website URL (`api_target_url`) and hostname
   (`tls_target_host`), assigned to that remote agent.
3. Optionally attach an **MTR Profile** (`/settings/networks/mtr`) to track
   hop-by-hop internet path latency and packet loss alongside passive RUM.

### C. Private WAN throughput & jitter (`netperf` over WireGuard)

For site-to-site WAN links (such as a branch office or remote cluster linked
over WireGuard or MPLS), use the embedded `netperf` runner inside
`serviceradar-agent` over your private overlay:

1. Open **Settings -> Networks -> Netperf** (`/settings/networks/netperf`).
2. Create **Netperf Responders** on two enrolled agents using their private
   LAN or WireGuard addresses (port `5199/TCP` mTLS + optional `5199/UDP`
   HMAC -- never expose `5199` publicly).
3. Create a bounded **Netperf Profile** (for example TCP bidirectional, 100
   Mbps ceiling, 5s duration, 1s omit, 300s interval).
4. Create a **Netperf Policy** (`hub_mesh` or `hub_and_spoke`) linking the
   profile and responders. Results stream into **Dashboards -> Network
   Performance** (`/dashboards/network-performance`), letting you compare
   site WAN throughput, loss, and jitter directly against `prefix_tag`-filtered
   LCP and TTFB in **Web RUM**.
