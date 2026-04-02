---
id: trivy-integration
title: Trivy Integration
sidebar_label: Trivy Integration
---

# Trivy Integration

The dedicated `trivy-sidecar` integration has been retired from the active `demo` deployment path.

Current state:

- there is no supported `k8s/demo` manifest for `serviceradar-trivy-sidecar`
- runtime cert generation no longer creates `trivy-sidecar` client certificates
- the demo NATS config no longer grants a dedicated `trivy.report.>` publisher identity

If this integration needs to return, recover the previous implementation from git history and reintroduce it intentionally rather than following the stale deployment flow that used to live here.
