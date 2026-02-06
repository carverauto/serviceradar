---
sidebar_position: 4
title: TLS Security
---

# TLS Security

ServiceRadar uses mutual TLS (mTLS) between internal services and edge agents. Certificates are issued by SPIFFE/SPIRE in Kubernetes and by the Compose certificate generator in Docker.

## Summary

- **Edge agents** connect to Agent-Gateway via gRPC mTLS on port 50052.
- **Core services** use SPIFFE identities for service-to-service mTLS.
- **Caddy / Ingress** terminates external TLS and forwards traffic to web-ng.

For deployment-specific TLS setup, see:

- [Docker Setup](./docker-setup.md)
- Kubernetes: SPIFFE/SPIRE is supported (configured via Helm values; no manual SPIRE operations are required for most installs).
