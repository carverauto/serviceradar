# Change: Add tenant usage metrics and capability hooks

## Why
The SaaS control plane needs plan-aware visibility and light-touch enforcement for hosted tenants, but the control plane is not the authoritative source of device inventory or in-product feature execution. Those decisions happen inside the ServiceRadar runtime.

We do not want to hard-wire SaaS billing logic into OSS ServiceRadar. We do need a small, neutral surface that lets external deployment layers observe usage and supply capability decisions. Without that surface, the control plane cannot show trustworthy plan utilization and cannot safely hide or block plan-restricted features such as collector onboarding.

## What Changes
- Define neutral Prometheus metrics for plan-relevant runtime usage such as managed-device count and collector inventory count.
- Define a minimal capability-hook model so external deployment systems can disable or hide selected features without embedding SaaS billing code throughout the product.
- Require collector-related UI and API surfaces to honor externally supplied capability flags when present.
- Keep the OSS design generic:
  - usage metrics are deployment-neutral
  - capability flags are deployment-neutral
  - SaaS pricing and billing policy remain outside this repository

## Impact
- Affected specs: `tenant-capabilities`
- Affected code: `web-ng`, `core-elx`, collector onboarding surfaces, Prometheus instrumentation, and configuration loading for capability flags
