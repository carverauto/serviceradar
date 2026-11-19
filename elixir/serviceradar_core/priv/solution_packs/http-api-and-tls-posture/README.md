# HTTP API and TLS Certificate Posture

First-party ServiceRadar Solution Pack (`io.serviceradar.http-api-and-tls-posture`) providing multi-step synthetic HTTP API journey monitoring with `httptrace` latency thresholds and TLS leaf certificate expiry checks.

## Included Resources

### Declarative Checks (2)
- `http-api-journey-health` -- Edge `http_journey` check verifying `/healthz` and `/readyz` endpoints with JSON assertions, optional `api_auth` credential slot binding, and `httptrace` latency thresholds.
- `tls-certificate-expiry-posture` -- Edge `tls_handshake` check inspecting `leaf_days_remaining` against configurable warning and critical day thresholds.

### Stateful Alert Rules (2)
- `http_api_journey_down` (`enabled`) -- Opens a critical alert when the synthetic HTTP API journey transitions to `down`.
- `tls_certificate_expiry_warning` (`paused`) -- Opt-in alert rule triggered when TLS leaf certificate validity enters the warning window.

### Authored Dashboards (1)
- `http-api-and-tls-overview` -- Unified SRQL overview dashboard tracking monitored synthetic endpoints, failing HTTP/TLS checks, and open posture alerts.
