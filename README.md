<div align=center>
  
[![Website](https://img.shields.io/website?up_message=SERVICERADAR&down_message=DOWN&url=https%3A%2F%2Fserviceradar.cloud&style=for-the-badge)](https://serviceradar.cloud)
[![Demo](https://img.shields.io/website?label=Demo&up_color=blue&up_message=DEMO&down_message=DOWN&url=https%3A%2F%2Fdemo.serviceradar.cloud&style=for-the-badge)](https://demo.serviceradar.cloud)
[![Apache 2.0 License](https://img.shields.io/badge/license-Apache%202.0-blueviolet?style=for-the-badge)](https://www.apache.org/licenses/LICENSE-2.0)

</div>

# ServiceRadar

<img width="1470" height="836" alt="Screenshot 2025-12-16 at 10 09 19 PM" src="https://github.com/user-attachments/assets/e64ca26b-f4d8-42df-ab81-2de1d7941f92" />

[![CI](https://github.com/carverauto/serviceradar/actions/workflows/main.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/main.yml)
[![Go Linter](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml)
[![Go Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml)
[![Rust Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml)

[![CNCF Landscape](https://img.shields.io/badge/CNCF%20Landscape-5699C6)](https://landscape.cncf.io/?item=observability-and-analysis--observability--serviceradar)
[![FOSSA Status](https://app.fossa.com/api/projects/custom%2B57999%2Fgit%40github.com%3Acarverauto%2Fserviceradar.git.svg?type=shield&issueType=security)](https://app.fossa.com/projects/custom%2B57999%2Fgit%40github.com%3Acarverauto%2Fserviceradar.git?ref=badge_shield&issueType=security)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/11310/badge)](https://www.bestpractices.dev/projects/11310)
<a href="https://cla-assistant.io/carverauto/serviceradar"><img src="https://cla-assistant.io/readme/badge/carverauto/serviceradar" alt="CLA assistant" /></a>
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/carverauto/serviceradar)

ServiceRadar is a distributed network monitoring system designed for infrastructure and services in hard-to-reach places or constrained environments. It provides real-time monitoring of internal services with cloud-based alerting to ensure you stay informed even during network or power outages.

## Features

- **Distributed Architecture**: Multi-component design (Agent, Gateway, Core) for flexible edge deployments.
- **WASM Plugin System**: Securely extend monitoring with custom checks in Go or Rust. Runs in a hardware-level sandbox with zero local dependencies and proxied networking.
- **SRQL**: intuitive key:value syntax for querying time-series and relational data.
- **Unified Data Layer**: Powered by CloudNativePG, TimescaleDB, and Apache AGE for relational, time-series, and graph topology data.
- **Observability**: Native support for OTEL, GELF, Syslog, SNMP (polling/traps), and NetFlow (planned).
- **Graph Network Mapper**: Discovery engine that maps interfaces and topology relationships via SNMP/LLDP/CDP.
- **Security**: Hardened with mTLS ([SPIFFE/spire](http://spiffe.io/)), RBAC, and SSO integration.

## WASM-Based Extensibility

ServiceRadar replaces traditional "script-and-shell" plugins with a modern WebAssembly runtime. This provides a generation leap in security and portability:

| Feature | ServiceRadar (Wasm) | Traditional NMS (Nagios/Zabbix) | Enterprise (SolarWinds) |
| :--- | :--- | :--- | :--- |
| **Isolation** | **Hardware Sandbox** | None (OS Process) | None (User Session) |
| **Dependencies** | **Zero** (Static Binaries) | High (Local Libs/Python) | High (.NET/Runtimes) |
| **Security** | Capability-based (Proxy) | Sudo/Root access | Local Admin / WMI |
| **Portability** | Cross-platform Wasm | Script-specific | Windows-centric |
| **Auditability** | Every network call logged | Invisible to Agent | Opaque |

**Why Wasm?** Plugins are "FS-less" by default. They cannot access the host filesystem or raw sockets. Instead, they use a **Network Bridge** where the Agent proxies specific HTTP/TCP calls based on admin-approved allowlists.

## Quick Installation (Docker Compose)

Get ServiceRadar running in under 5 minutes:

```bash
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
cp .env.example .env
docker compose up -d

# Get your admin password
docker compose logs config-updater | grep "Password:"
```

**Access:** http://localhost (login: `root@localhost`)

## Architecture

1. **Agent**: Lightweight Go service on monitored hosts; manages Wasm execution and local collection.
2. **Agent-Gateway**: Ingestion point that receives gRPC streams from edge agents.
3. **Core (core-elx)**: Control plane (Elixir/Phoenix) for orchestration, APIs, and alerts.
4. **Web UI (web-ng)**: Real-time LiveView dashboard for configuration and visualization.

## Documentation

For detailed guides on setup, security, and Wasm SDK usage, visit:
**[https://docs.serviceradar.cloud](https://docs.serviceradar.cloud)**

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. Join our [Discord](https://discord.gg/dhaNgF9d3g)! 

## License

Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
