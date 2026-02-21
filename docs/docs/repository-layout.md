---
sidebar_position: 7
title: Repository Layout
---

# Repository Layout

This page documents the canonical root-level repository layout after issue `#2851` cleanup.

## Canonical Root Layout

| Directory | Owner / Purpose |
|---|---|
| `go/` | Go services and shared Go packages (`go/cmd`, `go/pkg`, `go/internal`) |
| `elixir/` | Elixir applications (`web-ng`, `serviceradar_core`, `serviceradar_agent_gateway`, others) |
| `rust/` | Rust services/crates (collectors, SRQL, runtime helpers) |
| `database/` | Database assets (`age`, `timescaledb`) |
| `contrib/` | Contributed/optional assets (`snmp`, plugins) |
| `build/` | Build and release infrastructure (`packaging`, `release`, build scripts) |
| `proto/` | Protobuf schemas and generated bindings |
| `docker/` | Container build contexts and packaging Dockerfiles |
| `k8s/` | Kubernetes manifests and environment overlays |
| `docs/` | User and operator documentation site sources |
| `helm/` | Helm charts and chart values |
| `scripts/` | Repository-level operational/dev scripts |
| `alias/` | Bazel compatibility aliases (temporary, pending follow-up retirement plan) |
| `third_party/` | Bazel third-party integrations kept at root for compatibility |

## Migration Notes

- Legacy root paths (`cmd/`, `pkg/`, `internal/`, `web-ng/`, `packaging/`, `release/`, `age/`, `timescaledb/`, `snmp/`, `plugins/`) are no longer canonical.
- Use `elixir/web-ng` for all Phoenix app workflows.
- Use `build/packaging` and `build/release` for package/release workflows.
- Keep `alias/` and `third_party/` at root until their dedicated migration/retirement changes are approved.
