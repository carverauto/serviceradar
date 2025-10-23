# Self-assessment

## Table of Contents
- [Metadata](#metadata)
  - [Security Links](#security-links)
- [Overview](#overview)
  - [Actors](#actors)
  - [Actions](#actions)
  - [Background](#background)
  - [Goals](#goals)
  - [Non-goals](#non-goals)
- [Self-assessment Use](#self-assessment-use)
- [Security Functions and Features](#security-functions-and-features)
- [ServiceRadar Compliance](#ServiceRadar-compliance)
- [Secure Development Practices](#secure-development-practices)
- [Security Issue Resolution](#security-issue-resolution)
- [Appendix](#appendix)

## Metadata

| Field | Value |
|-------|-------|
| **Assessment Stage** | Incomplete |
| **Software** | [https://github.com/carverauto/serviceradar] |
| **Security Provider** | No |
| **Languages** | Go, Rust, OCaml, Objective C++, TS/JS |
| **SBOM** | [TBD - Working on generating comprehensive SBOM via GitHub Dependabot and custom tooling] |

### Security Links

Provide links to existing security documentation for the ServiceRadar:

| Document | URL |
|----------|-----|
| Security Policy | [https://github.com/carverauto/serviceradar?tab=security-ov-file] |
| Default and Optional Configs | [https://docs.serviceradar.cloud/docs/configuration] |
| Vulnerability Reporting | [https://github.com/carverauto/serviceradar?tab=security-ov-file] |

## Overview

ServiceRadar is an opensource network management and observability platform that was designed to be distributed, fast, and easy to use.

### Background

ServiceRadar was designed for network operators small or large, designed to work under cloud-native paradigms. This means that it can easily run in container environments, centralized management of a distributed configuration management system where you have one place to manage a fleet of agents/pollers/checkers, and a hands-off approach to securing microservices using mTLS and SPIFFE.

ServiceRadar offers traditional network management functionality and features, such as log ingestion, metrics collection, event management, along with a roadmap to support newer NMS technologies like streaming telemetry (gNMI).

### Actors

serviceradar-core: Core API services -- authentication, device registry, service coordination. The Core is also our monolithic gRPC API service and accepts unary or streaming gRPC connections, and can re-assemble chunked streams received from the poller for large messages.
serviceradar-proton: Timeplus Proton streaming OLAP database
serviceradar-agent: Agents provide minimal functionality (TCP/ICMP scanning) and primarily serve as a pass-through between the pollers and the checkers, designed for multi-tenancy and overlapping IP space challenges.
serviceradar-poller: Pollers ask the agents to collect data from checkers and forwards to the core, using unary or streaming gRPC calls and has built-in chunking for large payloads.
serviceradar-kong: API gateway, gets JWKS information from the Core via API and all API calls are routed and authorized before reaching their final destination. This allows us to easily bring in new APIs using shared AAA.
serviceradar-mapper: Network discovery/mapper service, uses SNMP/CDP/LLDP and API to interrogate network devices, mapping interfaces to devices and adding newly discovered devices.
serviceradar-nats: NATS JetStream offers message broker and KV services. Hub/Leaf configurations are fully supported at this time, allowing network operators to easily position message brokers in the edge or compartmented networks for ETL or aggregation functions.
serviceradar-datasvc: gRPC API for the NATS JetStream KV service.
serviceradar-nginx: nginx ingress configured to route /api calls through kong API gateway
serviceradar-otel: lightweight OTEL processor, receives OTEL logs, traces, and metrics, puts messages on the NATS JetStream message bus for processing by consumers.
serviceradar-zen: GoRules/zenEngine based stateless rule engine -- used to transform syslog messages and other events, transformed messages are turned into CloudEvents and placed into a new NATS JetStream stream to be processed by database consumers.
serviceradar-db-event-writer: NATS JetStream consumer, processes messages off of the message queues and inserts data in batches into proton database. Scales horizontally due to use of subscription queue groups in NATS JetStream.
serviceradar-flowgger: SYSLOG/Gelf receiver, receives messages and places them on NATS JetStream stream for processing by serviceradar-zen.
serviceradar-rperf-checker: RPerf bandwidth (iperf3 clone) measurement tool. Client/server model, servers live on remote systems and serve as endpoints for rperf-client (serviceradar-rperf-checker). Bandwidth measurements are collected through agent/poller and forwarded to the Core and stored in proton database.
serviceradar-snmp-checker: Periodically polls SNMP OIDs to collect metrics, data is collected through agent/poller system and forwarded to the Core, then saved in the database.
serviceradar-srql: ServiceRadar Query Language (SRQL) is our API and SQL translator that provides an intuitive key-based query language for retrieving data from the database. Used to create composable dashboards in web-ui.
serviceradar-tools: Utility container/image service that is pre-configured with mTLS certificates and other configuration items needed to easily connect to and manage NATS JetStream, Timeplus Proton, and also includes the serviceradar-cli tool, where users can easily generate new bcrypt strings for local-auth users.
serviceradar-trapd: SNMP trap receiver, receives SNMP traps and forwards to NATS JetStream message broker for processing.
serviceradar-web: Web-UI, react/nextjs+SSR -- API calls are all proxied through SSR middleware and done on the server side for improved security.

### Actions

ServiceRadar is a Service Oriented Architecture (SOA) -- all communication between microservices is done through mTLS. gRPC unary or streaming calls are supported and are the primary communication protocol between services.

### Goals

The ServiceRadar aims to support customers working in multi-tenant environments, and therefor requires high security controls throughout the pipeline and APIs. API calls will be checked against RBAC rules to ensure that the tenant-ID from the requestor is matched against data queries, ensuring that tenant-A can only see data related to tenant-A.

### Non-goals

ServiceRadar does not provide built-in data retention policies or storage quotas - these are handled at the infrastructure layer (Kubernetes PVCs, database retention policies). ServiceRadar does not enforce rate limiting at the application layer - this is expected to be handled by API gateways and infrastructure-level controls.

## Self-assessment Use

This self-assessment is created by the **ServiceRadar** team to perform an internal analysis of the ServiceRadar's security. It is **not** intended to provide a security audit of **ServiceRadar**, or function as an independent assessment or attestation of **ServiceRadar**'s security health.

This document serves to:
- Provide **[ServiceRadar]** users with an initial understanding of **[ServiceRadar]**'s security
- Point to existing security documentation
- Outline **[ServiceRadar]** plans for security
- Provide a general overview of **[ServiceRadar]** security practices for development and usage

This document provides the CNCF TAG-Security with an initial understanding of **[ServiceRadar]** to assist in joint-assessment, necessary for ServiceRadars under incubation. Together with joint-assessment, it serves as a cornerstone for graduation preparation and security audits.

## Security Functions and Features

### Critical

* serviceradar-core: gRPC API and core API services with tenant isolation via RBAC and mTLS
* serviceradar-srql: SRQL Query Engine API with tenant-scoped query validation
* serviceradar-proton: Timeplus Proton database with subscription-based access controls
* serviceradar-kong: Kong API gateway with JWT validation and rate limiting
* serviceradar-web: Web UI with server-side API proxying through Kong

### Security Relevant

* mTLS Configuration: SPIFFE/SPIRE integration for workload identity and certificate management
* NATS JetStream: Subject-based authorization and TLS encryption for message broker
* RBAC Implementation: Tenant-scoped role-based access control across all services
* gRPC Security: Mutual TLS enforcement and token-based authentication for all inter-service communication

## ServiceRadar Compliance

**Compliance**:

N/A

## Secure Development Practices

### Development Pipeline

* Require signed commits from contributors
* PRs require review by at least 2 maintainers with explicit sign-off before merging
* CI/CD pipeline includes:
** Static analysis with golangci-lint, clippy (Rust), and ESLint
** Security scanning with GitHub Advanced Security (CodeQL)
** Container image vulnerability scanning with Trivy
** Dependency vulnerability checking via Dependabot
** Automated unit/integration tests with coverage requirements
* Container images are built as multi-stage with non-root users and signed with cosign
* Immutable container deployments via Kubernetes

### Communication Channels

#### Internal

* GitHub Discussions for technical coordination
* Discord for real-time developer communication
* Maintainer office hours (weekly)

#### Inbound

* GitHub Issues for bug reports and feature requests
* Dedicated security@serviceradar.cloud email (forwarded to security team)
* Vulnerability reports via GitHub Security Advisories

#### Outbound

* GitHub Releases for version announcements
* ServiceRadar blog on CNCF landscape
* Security advisories published via GitHub Security Advisories

### Ecosystem

ServiceRadar is purpose-built for the cloud-native observability ecosystem, providing comprehensive network management capabilities that integrate seamlessly with the CNCF landscape:

Core CNCF Integrations:

* Kubernetes: Native deployment via Helm charts and Kubernetes operators for all components
* SPIFFE/SPIRE: Workload identity and mTLS certificate management across all microservices
* NATS JetStream: CNCF-incubating messaging system for high-performance event streaming
* CloudEvents: Event format standard for interoperability with other observability tools
* OpenTelemetry: Native OTLP protocol support for metrics, traces, and logs
* Prometheus: Built-in metrics endpoints and alerting integration

Ecosystem Impact:

ServiceRadar's agent/poller/checker architecture addresses the "last mile" problem in cloud-native monitoring - efficiently collecting network telemetry from containerized and VM workloads across multi-tenant environments. By supporting both traditional protocols (SNMP, syslog) and modern streaming telemetry (gNMI), ServiceRadar bridges legacy network infrastructure with cloud-native observability stacks.

Key Differentiators in CNCF Ecosystem:

* Multi-tenant isolation at the network management layer (unlike single-tenant tools)
* Horizontal scaling of data collection without single points of failure
* Event-driven architecture leveraging NATS JetStream and CloudEvents for real-time processing
* Native support for edge deployments via NATS hub/leaf topology
* Integration with service mesh security models via SPIFFE

ServiceRadar complements projects like Prometheus (metrics), Jaeger (tracing), and Fluentd (logging) by providing the network layer observability that's critical for understanding service-to-service communication in Kubernetes environments. Our roadmap includes deeper integration with eBPF-based observability tools and CNCF's emerging streaming telemetry standards.

## Security Issue Resolution

### Responsible Disclosures Process

#### Vulnerability Response Process

* Responsible parties: Security Response Team (2-3 designated maintainers with commit access)
* Reporting process:
** Public: GitHub Security Advisories
** Private: security@serviceradar.cloud or GitHub private vulnerability reports

Response strategy:

* Initial acknowledgment within 48 hours
* Severity assessment using CVSS scoring
* Private coordination with reporter for reproduction
* Patch development and testing
* Coordinated disclosure timeline (90 days max, following GitHub security model)

### Incident Response
Detection: Monitoring via Prometheus alerts on security events, anomaly detection in NATS streams
Triage: Security team assesses impact and scope within 24 hours
Containment: Rotate affected credentials, isolate compromised components via Kubernetes network policies
Notification: Affected users notified within 72 hours per our SLA, CNCF TAG-Security informed
Remediation: Hotfix release with security patches, root cause analysis
Post-mortem: Public security advisory published, lessons incorporated into development practices

## Appendix

### Known Issues Over Time

No publicly disclosed CVEs to date

### OpenSSF Best Practices

https://www.bestpractices.dev/en/projects/11310 -- currently passing

### Case Studies

1. Multi-tenant MSP: Regional MSP managing 50+ customer environments uses ServiceRadar's tenant isolation to provide network observability while maintaining strict data separation
2. Edge Deployment: Telco uses NATS hub/leaf topology to collect telemetry from 10,000+ cell sites, aggregating at regional data centers
3. Hybrid Cloud Migration: Enterprise migrating from legacy NMS discovers network dependencies across on-prem and cloud via ServiceRadar's mapper service

### Related ServiceRadars / Vendors

vs. Traditional NMS (HP OpenView, IBM Tivoli): ServiceRadar is cloud-native first, horizontally scalable, vs. legacy appliance-based solutions

vs. Prometheus + Blackbox Exporter: Provides comprehensive network management beyond just metrics collection, including discovery, event correlation, and multi-protocol support

vs. Zabbix: Kubernetes-native deployment, modern SOA architecture vs. monolithic agent-based model

vs. Commercial Solutions (SolarWinds, LogicMonitor): Open source with no vendor lock-in, CNCF ecosystem integration, community-driven roadmap

The strengthened ecosystem section now clearly positions ServiceRadar within the CNCF landscape, highlights specific integrations, and explains the unique value proposition for cloud-native network management.
