---
id: trivy-integration
title: Trivy Integration
sidebar_label: Trivy Integration
---

# Trivy Integration

ServiceRadar supports a [Trivy](https://trivy.dev/) integration for container image
vulnerability scanning. It is a supported integration — it is simply switched **off**
in the public demo environment for security reasons. You can enable it in your own
deployment.

## What It Does

The integration runs Trivy as a sidecar scanner alongside your workloads. It scans
container images for known CVEs and misconfigurations, then publishes the results as
structured vulnerability reports.

- **Scanning**: Trivy inspects container images and produces vulnerability findings
  (CVE ID, severity, affected package, fixed version).
- **Transport**: Reports are published over NATS JetStream on the `trivy.report.>`
  subject hierarchy.
- **Ingestion**: The core event-writer pipeline consumes those messages and persists
  them to the `trivy_reports` table in CNPG, where retention is managed alongside the
  rest of ServiceRadar's telemetry.
- **Querying**: Once ingested, vulnerability data is available for review through the
  ServiceRadar UI and SRQL like any other dataset.

## Status

- The integration is **supported** and actively maintained.
- It is **disabled in the demo environment** so the public demo does not run an
  image scanner or carry vulnerability data. This is an environment-specific choice,
  not a removal of the feature.

## Enabling Trivy

At a high level, enabling the integration in your own deployment requires:

1. **Deploy the Trivy sidecar** so it can scan the images you care about.
2. **Grant NATS publish access** for the `trivy.report.>` subject to the scanner's
   identity (and issue mTLS client certificates for it if your deployment uses mTLS
   for NATS).
3. **Confirm the event-writer pipeline** is consuming the `trivy_reports` stream —
   this processor is built into the core control plane and activates once reports
   begin arriving.

After the scanner is running and publishing, vulnerability reports flow into CNPG
automatically and become visible in the UI.

## Verifying

- Check that messages are arriving on the `trivy.report.>` subject in NATS.
- Confirm rows are landing in the `trivy_reports` table in CNPG.
- Review findings through the ServiceRadar UI.
