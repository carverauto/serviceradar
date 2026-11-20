---
sidebar_position: 1
title: Web Properties and RUM Overview
---

# Web Properties and Real User Monitoring (RUM)

ServiceRadar Real User Monitoring (RUM) pairs a sibling L7 **Web Property**
inventory (`in:websites`) with **Akamai `boomerang.js`** (`boomerang-sr.min.js`)
beacon ingestion so you can correlate Core Web Vitals, CDN edge-vs-origin
latency, corporate branch WAN health (`prefix_tags`), synthetic HTTP/TLS
checks, and backend OpenTelemetry traces in one place.

## Why Web Properties are separate from Devices

ServiceRadar's `Device` inventory (`ocsf_devices` and DIRE) models L2/L3 hosts
by MAC address, serial number, agent ID, and IP. Public websites are L7
services:

- Behind a CDN such as Akamai or Cloudflare, DNS resolves a site to rotating
  regional Anycast VIPs.
- Multiple websites frequently share a single Kubernetes Gateway VIP or load
  balancer IP.

Modeling websites as `ServiceRadar.Inventory.WebProperty` (`in:websites`) keeps
rotating CDN VIPs out of `ocsf_devices` and prevents false DIRE merges, while
still linking each website down to underlying infrastructure via
`WebPropertyBinding`:

- **Kubernetes public endpoints** (`HTTPRoute` / `Ingress` hostnames)
- **Origin devices** (operator-declared or direct non-CDN VIP match)
- **OpenTelemetry services** (via W3C `traceparent` correlation)
- **Active synthetic checks** (`ServiceCheck` and Solution Packs such as
  `io.serviceradar.http-api-and-tls-posture`)

## Data flow

```text
Browser (boomerang-sr.min.js or Akamai mPulse tee)
   |
   | POST https://rum.example.com/rum/v1/beacon?key=sr_rum_...
   v
Gateway API HTTPRoute / Akamai CDN
   |
   v
Rust Collector (/rum/v1/beacon)
   |-- Validate rum_site_key + Origin against NATS-synced policy cache
   |-- Enforce 64 KiB body cap and per-key / per-subnet token buckets
   |-- Strip URL query strings and fragments (keep allowlisted non-PII keys)
   |-- Parse W3C Server-Timing (Akamai cdn-cache, edge, origin, ak_p)
   |-- Resolve prefix_tags and Geo/ASN in memory, then truncate client IP
   |-- Publish RumBeaconV1 -> NATS JetStream (rum.beacons.<web_property_id>)
   +-- Publish MetricBatch -> NATS JetStream (metrics.rum.>)
                                  |
                                  v
                  ServiceRadar EventWriter
                   |-- StarRocks enabled  -> StarRocks rum_beacons + timeseries_metrics
                   +-- StarRocks disabled -> CNPG rum_beacons + timeseries_metrics
```

All telemetry flows through NATS JetStream first and writes to the single
active telemetry store (StarRocks when enabled, CNPG otherwise; never both).

## Creating a Web Property

Navigate to **Websites** (`/websites`) and click **+ Add Web Property**:

| Field | Description | Example |
|---|---|---|
| **Name** | Human-readable label for the site. | `Example Storefront` |
| **Canonical Origin** | Normalized `scheme://host[:port]` unique key. | `https://shop.example.com` |
| **Environment** | `Production`, `Staging`, `Development`, or `Internal`. | `Production` |
| **Allowed CORS Origins** | Comma- or newline-separated origins permitted to POST beacons. | `https://shop.example.com, https://www.shop.example.com` |
| **Allowed Query Keys (non-PII)** | Optional query keys retained after URL scrubbing. All other query parameters and fragments are stripped at ingress. | `utm_source, utm_medium, utm_campaign, ref` |
| **Trace Propagate Origins** | Optional cross-origin API origins allowed to receive W3C `traceparent` headers. Leave blank for same-origin only. | `https://api.example.com` |
| **RUM Sample Rate** | Fraction of sessions sampled (`0.0` to `1.0`). | `1.0` |
| **RUM Enabled** | Enables or pauses beacon ingestion for this property. | Checked |
| **Anonymize IP** | Zeroes `/24` IPv4 and `/48` IPv6 client addresses after `prefix_tags` and Geo/ASN lookup. | Checked |

After saving, open the property detail page (`/websites/:id`) to view its
generated **`rum_site_key`** (`sr_rum_...`) and onboarding snippets. You can
rotate `rum_site_key` at any time; the collector invalidates the previous key
automatically via NATS policy updates.

:::note Public routing key, not a secret
`rum_site_key` is a public write-only routing and rate-limiting identifier
embedded in HTML served to browsers. It never grants read access to ServiceRadar
or OTLP ingestion. Internal OTLP tokens are never exposed to browsers.
:::

## Privacy and security controls at ingress

The Rust collector enforces these protections before any beacon reaches NATS
JetStream:

- **Site-key + `Origin` gate**: Unknown or rotated keys and disallowed origins
  are rejected in memory without querying CNPG.
- **Payload and rate limits**: Request bodies are capped at 64 KiB with
  per-key and per-subnet (`/24` IPv4, `/48` IPv6) token-bucket rate limits.
- **PII scrubbing**: Query strings (`?token=...`) and fragments (`#...`) are
  stripped from page URLs and referrers by default, keeping only explicitly
  allowlisted non-PII keys.
- **IP anonymization**: Client IPs are matched against `prefix_tags` and
  Geo/ASN in memory and then truncated (`/24` / `/48`) before persistence when
  **Anonymize IP** is enabled.

## Querying RUM data with SRQL and dashboards

ServiceRadar ships a built-in **Web RUM** dashboard
(`cloud.serviceradar.web-rum`) showing p75 Core Web Vitals (LCP, INP, CLS,
FCP, TTFB), Edge vs. Origin RTT vs. Browser Render breakdowns, Akamai CDN cache
status, branch `prefix_tags` / ASN cohorts, and route hotspots.

You can also query Web Properties and beacons directly with SRQL:

```sql
in:websites sort:name:asc limit:50
```

```sql
in:rum time:last_1h sort:observed_at:desc limit:50
```

```sql
in:rum time:last_24h cdn_cache_status:MISS lcp_ms:>2500 limit:50
```

## Next steps

- [Instrumenting Websites with Boomerang](./rum-instrumentation.md)
- [Akamai CDN and Server-Timing Integration](./rum-akamai-cdn.md)
