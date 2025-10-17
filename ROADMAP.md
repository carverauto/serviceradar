# ServiceRadar Project Roadmap

## Overview

ServiceRadar is an open-source network management and observability platform designed to be distributed, fast, and easy to use. This roadmap outlines our vision for the project as we prepare for donation to the Cloud Native Computing Foundation (CNCF).

## Elevator Pitch

ServiceRadar is a distributed network monitoring and observability platform that works seamlessly across bare metal, Docker, and Kubernetes environments. It provides comprehensive network visibility through log collection, SNMP and Network Management APIs, metric polling, and network discovery—all queryable through an intuitive DSL called SRQL. Built for performance and scalability, ServiceRadar delivers enterprise-grade observability without the enterprise price tag.

---

## Current Capabilities (v1.x)

### Core Platform
- **Multi-Environment Support**: Bare metal, Docker, and Kubernetes deployments
- **Distributed Architecture**: Agent-Poller-Core design for scalability and reliability
- **Stream Processing**: Powered by Timeplus Proton (90M EPS, 4ms latency)
- **Multi-Platform**: AMD64 and ARM64 support (including Apple Silicon, Raspberry Pi)

### Data Collection & Observability
- **Log Aggregation**: GELF and Syslog collection via Flowgger
- **SNMP Integration**: Metric polling and trap collection
- **Network Discovery**: SNMP/LLDP/CDP-based device and topology discovery
- **Service Monitoring**: Process, port, and service health checks
- **Performance Monitoring**: Built-in rperf network performance testing

### Query & Analysis
- **SRQL (ServiceRadar Query Language)**: Intuitive key:value syntax for data exploration
- **Real-Time Streaming**: Live queries on streaming data
- **ClickHouse Compatibility**: Leverage existing ClickHouse ecosystem

### Security & Identity
- **mTLS Communication**: Secure inter-component communication
- **API Key Authentication**: Secure API access
- **JWT Session Management**: Web UI authentication
- **Role-Based Access**: Component-level security isolation
- **Partial SPIFFE/SPIRE**: Initial implementation for service identity/mTLS certificate management

### Management & Configuration
- **Web UI**: Modern React-based dashboard with SSR
- **KV Store**: NATS JetStream-based configuration management
- **Device Registry**: Canonical identity management with deduplication
- **Sync Service**: External system integration (Armis, NetBox)
- **Custom Checkers**: Extensible plugin system for monitoring

### Deployment
- **Docker Compose**: One-command deployment with all components
- **Multi-Architecture Images**: AMD64 and ARM64 support
- **Installation Scripts**: Automated native installation

---

## Short-Term Goals (6-12 Months)

### Q1 2026: Production Hardening & CNCF Onboarding
- [ ] **Helm Chart**: Official Kubernetes deployment via Helm
- [ ] **Documentation**: Comprehensive deployment, operations, and troubleshooting guides
- [ ] **Security Audit**: Third-party security assessment and remediation
- [ ] **Performance Benchmarks**: Published performance characteristics and tuning guides
- [ ] **CNCF Sandbox Application**: Submit project for CNCF Sandbox status

### Q2 2026: Enhanced Observability
- [ ] **OCSF Alignment**: Migrate to Open Cybersecurity Schema Framework data formats
- [ ] **Enhanced eBPF/Profiler**: Advanced APM capabilities with eBPF-based profiling
- [ ] **Win32 Agents**: Windows platform support for agents
- [ ] **Darwin/ARM64 Sysmon**: macOS and ARM64 system monitoring
- [ ] **Enhanced Sysmon VM/Container**: Improved Docker and VM monitoring capabilities

### Q3 2026: Data Platform Evolution
- [ ] **NetFlow Support**: NetFlow/IPFIX data collection and analysis
- [ ] **BGP BMP Integration**: BGP monitoring protocol support
- [ ] **ClickHouse Integration**: Direct ClickHouse integration alongside Timeplus Proton
- [ ] **Graph Database Integration**: dgraph/equivalent for network topology and discovery
- [ ] **Enhanced Mapper/Discovery**: Improved network discovery engine with AI/ML-assisted topology mapping

---

## Medium-Term Goals (12-24 Months)

### Platform Modernization
- [ ] **Config Migration to KV**: Move all configuration to KV store for dynamic updates
- [ ] **UI Config Management**: Full configuration management through Web UI
- [ ] **One-Touch Agent Deployment**: Automated agent provisioning and deployment
- [ ] **KV Backup & Restore**: Comprehensive backup/restore for KV-stored configurations
- [ ] **Remote PCAP collection/Wireshark**: Browser-based packet capture and analysis

### Enterprise Features
- [ ] **SSO Integration**: Complete single sign-on support (OAuth2/OIDC)
- [ ] **SAML Integration**: SAML 2.0 for enterprise identity federation
- [ ] **Advanced RBAC**: Granular role-based access control
- [ ] **Multi-Tenancy**: Tenant isolation and resource quotas
- [ ] **Audit Logging**: Comprehensive audit trail for compliance

### SIEM & Security
- [ ] **SIEM Capabilities**: Security information and event management features
- [ ] **Threat Intelligence**: VulnCheck and other TI feed integration
- [ ] **Anomaly Detection**: ML-based anomaly detection for network behavior
- [ ] **Compliance Reporting**: Pre-built compliance dashboards (PCI-DSS, SOC2, etc.)

### Integration & Ecosystem
- [ ] **NetBox Deep Integration**: Enhanced DCIM/IPAM synchronization
- [ ] **MCP Server Updates**: Model Context Protocol server improvements
- [ ] **OpenTelemetry Native**: Full OTel protocol support for traces, metrics, and logs
- [ ] **Prometheus Exporter**: Native Prometheus metrics export

---

## Long-Term Vision (24+ Months)

### Next-Generation Architecture
- [ ] **BEAM VM PoC**: Proof-of-concept agent/poller implementation in Elixir or Gleam
  - Leverage OTP supervision trees for fault tolerance
  - Hot code reloading for zero-downtime updates
  - Distributed Erlang for cluster coordination
- [ ] **Mature Plugin System**: Comprehensive checker/plugin framework with marketplace
- [ ] **Edge Computing**: Lightweight edge deployment for IoT and remote sites
- [ ] **Service Mesh Integration**: Istio/Linkerd integration for microservices observability

### Advanced Analytics
- [ ] **ML/AI Pipeline**: Integrated ML pipeline for predictive analytics
- [ ] **Capacity Planning**: AI-driven capacity forecasting
- [ ] **Root Cause Analysis**: Automated RCA using topology and telemetry correlation
- [ ] **Self-Healing**: Automated remediation for common issues

### Cloud Native Ecosystem
- [ ] **CNCF Incubation**: Progress toward CNCF Incubating status
- [ ] **Multi-Cloud Support**: Native integrations for AWS, Azure, GCP
- [ ] **Operator Pattern**: Kubernetes operators for advanced lifecycle management
- [ ] **GitOps Integration**: ArgoCD/Flux integration for configuration as code

### Data & Storage
- [ ] **Tiered Storage**: Hot/warm/cold data tiering
- [ ] **Data Retention Policies**: Automated data lifecycle management
- [ ] **Time-Series Optimization**: Advanced compression and indexing
- [ ] **Distributed Query**: Federated queries across multiple clusters

---

## Community & Governance

### Open Source Community
- [ ] **Contributor Guidelines**: Clear contribution pathways and recognition
- [ ] **Community Calls**: Regular public meetings and roadmap discussions
- [ ] **Special Interest Groups**: SIGs for security, networking, integrations, etc.
- [ ] **Mentorship Program**: Onboarding for new contributors

### Documentation & Education
- [ ] **Tutorial Series**: Step-by-step guides for common use cases
- [ ] **Video Content**: Video tutorials and demos
- [ ] **Best Practices**: Published operational best practices
- [ ] **Certification Program**: ServiceRadar administrator certification

### Ecosystem Growth
- [ ] **Integration Marketplace**: Community-contributed integrations and plugins
- [ ] **Reference Architectures**: Published deployment patterns for various scales
- [ ] **Partner Program**: Formal partnerships with complementary projects
- [ ] **Conference Presence**: Regular talks at KubeCon, FOSDEM, etc.

---

## Technical Debt & Maintenance

### Ongoing Work
- [ ] **Flowgger GELF Support**: Extend Flowgger to natively support GELF (currently syslog-only)
- [ ] **Code Coverage**: Increase test coverage to >80%
- [ ] **API Versioning**: Formal API versioning and stability guarantees
- [ ] **Dependency Updates**: Automated dependency updates and security scanning
- [ ] **Performance Regression Testing**: Continuous performance monitoring in CI/CD

### Complete SPIFFE/SPIRE Integration
- [ ] **Kubernetes**: Full SPIFFE/SPIRE integration for K8s deployments
- [ ] **Docker**: SPIFFE/SPIRE for Docker Compose deployments
- [ ] **Bare Metal**: SPIFFE/SPIRE for traditional deployments

---

## Success Metrics

### Adoption
- 1,000+ GitHub stars
- 100+ production deployments
- 50+ active contributors
- 10+ corporate sponsors/contributors

### Performance
- 100M+ EPS throughput
- <3ms end-to-end latency
- 99.99% uptime in HA deployments
- Support for 1,000,000+ monitored endpoints per cluster

### Community Health
- Monthly releases
- <48 hour average PR review time
- <7 day average issue triage time
- Active community forum/Slack

---

## How to Contribute

We welcome contributions in all areas:

- **Code**: Features, bug fixes, performance improvements
- **Documentation**: Tutorials, guides, translations
- **Testing**: Bug reports, integration testing, performance testing
- **Community**: Help users, write blog posts, give talks

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

---

## Release Cadence

- **Major releases**: Every 6 months (breaking changes, major features)
- **Minor releases**: Monthly (new features, non-breaking changes)
- **Patch releases**: As needed (bug fixes, security updates)

---

## Get Involved

- **GitHub**: [https://github.com/carverauto/serviceradar](https://github.com/carverauto/serviceradar)
- **Documentation**: [https://docs.serviceradar.cloud](https://docs.serviceradar.cloud)
- **Demo**: [https://demo.serviceradar.cloud](https://demo.serviceradar.cloud)

---

*This roadmap is a living document and will be updated quarterly based on community feedback, technical discoveries, and ecosystem evolution.*

**Last Updated**: 2025-10-16
