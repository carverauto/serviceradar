---
sidebar_position: 2
title: Instrumenting Websites (Boomerang)
---

# Instrumenting Websites with Boomerang

ServiceRadar packages a first-party `boomerang-sr.min.js` bundle (`akamai/boomerang`
BSD-3-Clause plus the `ServiceRadarTrace` W3C `traceparent` plugin) served by
`web-ng` at:

```text
https://<serviceradar-web-ng-host>/assets/rum/boomerang-sr.min.js
```

Beacons are posted to the collector's public-safe endpoint:

```text
https://<serviceradar-rum-host>/rum/v1/beacon
```

## 1. Expose `/rum/v1/beacon` in Helm

Keep internal OTLP ingestion (`/v1/{traces,logs,metrics}` and gRPC) private on
your cluster or LAN, and expose **only** `/rum/v1/beacon` on a dedicated
public hostname using `logCollector.otlp.gateway.rumHostname`:

```yaml
logCollector:
  otlp:
    http:
      tlsEnabled: false
    service:
      enabled: true
      http:
        enabled: true
    gateway:
      enabled: true
      gatewayName: "serviceradar-shared-gateway"
      gatewayNamespace: "serviceradar-system"
      httpSectionName: "https-web"
      # Keep OTLP/HTTP (/v1/*) and OTLP/gRPC off the public gateway:
      httpHostname: ""
      grpcHostname: ""
      # Expose only the key- and Origin-gated /rum/v1/beacon route:
      rum:
        enabled: true
      rumHostname: "rum.example.com"
```

This renders a dedicated `serviceradar-rum-http` `HTTPRoute` matching only
`PathPrefix: /rum/v1/beacon` and forwarding to `serviceradar-otlp:4318`.

:::tip Wildcard TLS certificate constraint
Single-label wildcard listeners such as `*.example.com` match one label only.
Use `rum-demo.example.com`, not `rum.demo.example.com`, when attaching to a
`*.example.com` listener.
:::

## 2. Standard HTML snippet

For sites that allow inline configuration scripts, copy the snippet directly
from `/websites/:id` into `<head>`:

```html
<script>
  window.BOOMR_config = window.BOOMR_config || {};
  window.BOOMR_config.ServiceRadar = {
    siteKey: "sr_rum_example_site_key",
    beaconUrl: "https://rum.example.com/rum/v1/beacon",
    sampleRate: 1.0,
    tracePropagateOrigins: []
  };
</script>
<script
  src="https://sr.example.com/assets/rum/boomerang-sr.min.js"
  async
  crossorigin="anonymous"
></script>
```

## 3. CSP-safe setup (no `unsafe-inline`)

If your site enforces a strict `Content-Security-Policy` without
`'unsafe-inline'` in `script-src`, pass the configuration through a `<meta>`
tag and initialize `window.BOOMR_config.ServiceRadar` inside your bundled
`app.js`:

### HTML layout (`<head>`)

```html
<meta
  name="serviceradar-rum-config"
  content='{"siteKey":"sr_rum_example_site_key","beaconUrl":"https://rum.example.com/rum/v1/beacon","sampleRate":1.0,"tracePropagateOrigins":[]}'
/>
<script defer src="/assets/js/app.js"></script>
<script
  defer
  crossorigin="anonymous"
  src="https://sr.example.com/assets/rum/boomerang-sr.min.js"
></script>
```

Because both scripts use `defer`, the browser downloads them in parallel and
executes `app.js` before `boomerang-sr.min.js`.

### Application bundle (`app.js`)

```js
const rumMeta = document.querySelector('meta[name="serviceradar-rum-config"]');
if (rumMeta && rumMeta.content) {
  try {
    const rumConfig = JSON.parse(rumMeta.content);
    if (rumConfig && rumConfig.siteKey && rumConfig.beaconUrl) {
      window.BOOMR_config = window.BOOMR_config || {};
      window.BOOMR_config.ServiceRadar = {
        siteKey: rumConfig.siteKey,
        beaconUrl: rumConfig.beaconUrl,
        sampleRate: rumConfig.sampleRate ?? 1.0,
        tracePropagateOrigins: Array.isArray(rumConfig.tracePropagateOrigins)
          ? rumConfig.tracePropagateOrigins
          : [],
      };
    }
  } catch (_error) {
    // Ignore malformed RUM config metadata.
  }
}
```

### Content-Security-Policy headers

Allow the script origin in `script-src` and the beacon origin in `connect-src`:

```http
Content-Security-Policy: script-src 'self' https://sr.example.com; connect-src 'self' https://rum.example.com;
```

No `'unsafe-inline'` is required.

## 4. Runtime environment variables for Kubernetes deployments

To keep `rum_site_key` rotatable without rebuilding container images, read RUM
settings from runtime environment variables (one-time setup per site in your
Deployment or ConfigMap):

| Environment Variable | Required | Description |
|---|---|---|
| `SERVICERADAR_RUM_SITE_KEY` | Yes | Public `sr_rum_...` key from `/websites/:id`. |
| `SERVICERADAR_RUM_BEACON_URL` | Yes | Full collector beacon URL, e.g. `https://rum.example.com/rum/v1/beacon`. |
| `SERVICERADAR_RUM_SCRIPT_URL` | Yes | Full bundle URL, e.g. `https://sr.example.com/assets/rum/boomerang-sr.min.js`. |
| `SERVICERADAR_RUM_SAMPLE_RATE` | No | Float in `0.0..1.0` (default `1.0`). |
| `SERVICERADAR_RUM_TRACE_PROPAGATE_ORIGINS` | No | Comma-separated cross-origin API origins for W3C `traceparent` injection. |

Leave the three required variables unset in local development or CI to keep RUM
disabled cleanly.

## 5. Dual-shipping from an existing Akamai mPulse deployment

If your site already loads Akamai mPulse (`boomerang.js`), do not load a second
Boomerang bundle. Subscribe to mPulse's `beacon` event and tee beacons to
ServiceRadar:

```html
<script>
  (function () {
    function attachTee() {
      if (!window.BOOMR || typeof window.BOOMR.subscribe !== "function") return;
      window.BOOMR.subscribe("beacon", function (vars) {
        try {
          var body = new URLSearchParams();
          Object.keys(vars || {}).forEach(function (k) {
            if (vars[k] !== undefined && vars[k] !== null) body.append(k, String(vars[k]));
          });
          navigator.sendBeacon(
            "https://rum.example.com/rum/v1/beacon?key=sr_rum_example_site_key",
            body
          );
        } catch (_err) {}
      });
    }
    if (window.BOOMR) attachTee();
    document.addEventListener("onBoomerangLoaded", attachTee);
  })();
</script>
```

## 6. W3C `traceparent` correlation

`BOOMR.plugins.ServiceRadarTrace` automatically attaches a W3C `traceparent`
header (`00-<trace_id>-<span_id>-01`) to same-origin `fetch` and
`XMLHttpRequest` calls and records `sr.trace_id` on the beacon so slow page
loads link directly to backend OpenTelemetry traces.

Cross-origin APIs are **not** tagged by default so CORS preflights do not break.
To opt in a cross-origin API:

1. Add its origin (for example `https://api.example.com`) to **Trace Propagate
   Origins** on the Web Property and in `tracePropagateOrigins`.
2. Ensure that API includes `traceparent` in its
   `Access-Control-Allow-Headers` response header.

## 7. Verification checklist

1. Open your instrumented website in a browser with DevTools **Network** open.
2. Confirm `boomerang-sr.min.js` loads with HTTP `200` and no CSP console
   errors.
3. Confirm `POST https://rum.example.com/rum/v1/beacon?key=sr_rum_...` returns
   HTTP `204` (or `200`).
4. In ServiceRadar, open **Dashboards -> Web RUM** or run:
   ```sql
   in:rum time:last_1h sort:observed_at:desc limit:20
   ```
