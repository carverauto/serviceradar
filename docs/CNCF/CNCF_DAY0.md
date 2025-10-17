# General Technical Review - ServiceRadar

## Project Information

| Field | Value |
|-------|-------|
| **Project** | ServiceRadar |
| **Version** | 1.0.53 |
| **Website** | https://serviceradar.cloud |
| **Date Updated** | 2025-10-17 |
| **Template Version** | v1.0 |
| **Description** | Open-source network management and observability platform designed for cloud-native environments, providing secure, scalable monitoring for large-scale networks (100k+ devices) |

---

## Day 0 - Planning Phase

### Scope

#### Roadmap Process

ServiceRadar follows a dual-track roadmap:

1. **Mature NMS Functionality**: SNMP polling, syslog processing, device discovery, event correlation (comparable to Zabbix/SolarWinds)
2. **Carrier-Grade Scalability**: Architecture supporting 100,000-1,000,000+ devices where traditional NMS systems fail

**Roadmap Governance:**
- Features prioritized via GitHub Discussions and quarterly maintainer planning sessions
- Community feedback incorporated through Issue analysis and user interviews (planned Q1 2026)
- Maps to contributor ladder:
  - **Level 1**: Documentation, bug fixes
  - **Level 2**: Feature implementation
  - **Level 3**: Architecture decisions

**Current Roadmap**: https://github.com/carverauto/serviceradar/blob/main/ROADMAP.md

#### Target Personas

| Persona | Organization Examples | Use Case |
|---------|----------------------|----------|
| Network Engineers | AT&T, Verizon, T-Mobile | Carrier-grade network monitoring |
| Platform Operators | United Airlines, American Airlines | Airport/operations network management |
| Energy Grid Operators | Duke Energy, Pacific Gas & Electric | SCADA and grid infrastructure monitoring |
| MSP Engineers | Regional managed service providers | Multi-tenant customer network management |
| IoT Platform Teams | Industrial IoT, smart city platforms | Large device fleet monitoring (10k-1M devices) |
| Security Operations | Internet companies (Cloudflare-scale) | Network-layer SIEM integration |

#### Use Cases

**Primary: Network Management & Observability**

ServiceRadar provides secure-by-design network management for cloud-native environments:

- **Multi-tenant isolation**: Agent/poller/checker architecture supporting overlapping IP spaces and separate security domains
- **Cloud-native deployment**: Kubernetes-native with Helm charts, microservices secured by mTLS via SPIFFE/SPIRE
- **Event-driven architecture**: NATS JetStream for reliable message delivery and horizontal scalability, using CloudEvents for event standardization
- **Stream processing**: Timeplus Proton for real-time data processing and analysis
- **Stateless rules**: ZenEngine-based rule editor (web UI) for event transformation without service restarts
- **Centralized configuration**: NATS KV-based fleet management (ETA: November 2025)
- **Memory-safe implementation**: Network-facing systems written in Rust; core logic in Go/OCaml

**Additional Use Cases:**

| Use Case | Implementation | Status |
|----------|----------------|--------|
| **AI Ops** | Stream processing with ZenEngine rules for anomaly detection and predictive maintenance | Beta (Q4 2025) |
| **SIEM Integration** | Syslog/SNMP traps → NATS → CEF/LEEF export to Splunk/QRadar | Production-ready |
| **Edge Computing** | NATS hub/leaf topology for remote site data aggregation before cloud transmission | Production-ready |
| **Hybrid Monitoring** | Unified visibility across on-premises, cloud, and edge infrastructure | Production-ready |

#### Unsupported Use Cases

| Unsupported | Recommended Alternative |
|-------------|------------------------|
| Application-level APM | OpenTelemetry, Jaeger, DataDog |
| Desktop/endpoint monitoring | Osquery, Wazuh |
| Mobile app management | Firebase, AppCenter |
| Non-IP protocols | Protocol-specific tools |
| Log aggregation platform | Elasticsearch, Loki, Splunk |

#### Intended Organizations

**Primary targets:**
- **MSPs**: Multi-tenant service providers requiring strict tenant isolation (50-1000+ customers)
- **Telecommunications**: Carriers managing 10k-1M+ network elements
- **Energy & Utilities**: Smart grid, SCADA, and distributed asset monitoring
- **Airlines**: Airport operations, flight systems, distributed site networks
- **IoT Platforms**: Device manufacturers and platform providers
- **Internet Companies**: CDN providers, hosting companies, cloud-scale infrastructure

**Organization characteristics:**
- 1,000+ monitored devices/endpoints
- Multi-site or geographically distributed networks
- Hybrid infrastructure (on-premises + cloud)
- Compliance requirements (GDPR, PCI-DSS, SOC 2)
- Multi-tenant or MSP business model

#### End User Research

**Current status**: Early stage; anecdotal feedback from pilot deployments

**Planned research:**
- User interviews with pilot customers (Q1 2026)
- Community survey on feature priorities (Q1 2026)
- Usability testing sessions for web UI (Q2 2026)

**Existing feedback sources:**
- GitHub Issues and Discussions
- Discord community engagement
- Direct pilot customer feedback

---

### Usability

#### Target Persona Interaction

**Quick start (5 minutes):**
```bash
# Kubernetes (Recommended)
helm repo add serviceradar https://carverauto.github.io/helm-charts
helm install serviceradar serviceradar/serviceradar

# Docker Compose (Evaluation)
docker compose up -d
```

#### User Experience by Deployment Method

| Deployment | Experience | Configuration | Complexity | Best For |
|------------|-----------|---------------|------------|----------|
| **Kubernetes** | Excellent | Helm values + Web UI (KV config coming Nov 2025) | Low | Production, multi-node |
| **Docker Compose** | Good | JSON files + docker-compose.yml | Medium | Development, POC |
| **Bare Metal** | Complex | Scripts + manual mTLS cert generation | High | Air-gapped, specialized |

#### Configuration Evolution

**Current (v1.0.53):**
- Manual JSON configuration files per service
- RBAC policies in Kubernetes Secrets
- Certificate management via SPIFFE/SPIRE

**Migration (November 2025):**
- NATS KV-based centralized configuration
- Web UI configuration management
- Fleet updates without service restarts
- GitOps-friendly configuration versioning

#### Web UI Features

**Technology**: React/Next.js with server-side rendering

**Current capabilities:**
- Device inventory and status dashboards
- Real-time metrics visualization
- SRQL query builder for ad-hoc analysis
- Alert configuration and management
- User and tenant management

**Coming soon (Q4 2025-Q1 2026):**
- ZenEngine rule editor (visual workflow builder)
- Configuration management via NATS KV
- Multi-tenant admin portal
- Custom dashboard builder

**UX characteristics:**
- Responsive design (mobile/tablet/desktop)
- WCAG 2.1 accessibility compliance
- Sub-second page loads with SSR
- Real-time updates via WebSockets

#### Production Integration

**Kubernetes ecosystem:**

| Integration | Implementation |
|-------------|----------------|
| **Deployment** | Helm charts, Kubernetes Operators (roadmap) |
| **CRDs** | ServiceRadarTenant, ServiceRadarDevice (Q1 2026) |
| **Networking** | NetworkPolicies for pod-to-pod security |
| **Storage** | PVCs with StorageClass flexibility |
| **Monitoring** | ServiceMonitor for Prometheus scraping |
| **Secrets** | External Secrets Operator compatible |

**Legacy NMS compatibility:**

| Protocol | Support Level | Notes |
|----------|--------------|-------|
| **SNMPv1/v2c/v3** | Full | Bulk operations, MIB parsing |
| **Syslog (RFC 3164/5424)** | Full | TCP/UDP, TLS encryption |
| **SNMP Traps** | Full | v1/v2c/v3 trap reception |
| **NetFlow/IPFIX** | Via goflow2+ | Template caching, aggregation |
| **Cisco CDP/LLDP** | Full | Auto-discovery, topology mapping |

**Observability ecosystem:**

```
External Sources → serviceradar-otel (OTLP collector) → NATS JetStream → Proton DB
                ↓
Syslog/GELF    → serviceradar-flowgger → NATS JetStream → serviceradar-zen (rules) → Proton DB
```

ServiceRadar provides its own:
- **serviceradar-otel**: Lightweight OTEL collector for traces, logs, and metrics (OTLP protocol)
- **serviceradar-flowgger**: High-performance syslog/GELF receiver
- Both forward to NATS JetStream for processing and storage in Timeplus Proton

**Multi-tenant architecture:**
- RBAC with tenant-scoped queries
- Kubernetes NetworkPolicies per tenant namespace
- Separate data retention policies per tenant
- Isolated agent/poller deployments

---

### Design

#### Design Principles

| Principle | Implementation | Benefit                                                |
|-----------|----------------|--------------------------------------------------------|
| **Secure by Default** | mTLS enforced, Rust for network-facing code, no default passwords | Zero trust networking, memory safety                   |
| **Event-Driven Scalability** | NATS JetStream messaging, async processing | Horizontal scaling, fault isolation, CloudEvents based |
| **Fault Tolerant** | Distributed pollers, circuit breakers, retry logic | 99.9% availability during component failures           |
| **Cloud Native** | SPIFFE/SPIRE identity, Kubernetes-first, container-native | Easy deployment, vendor-neutral                        |
| **Multi-tenant Isolation** | RBAC, network policies, tenant-scoped queries | Security compliance, MSP-ready                         |

#### Architecture Requirements

**Full documentation**: https://github.com/carverauto/serviceradar/tree/main/sr-architecture-and-design

**Environment-specific configurations:**

| Environment | Key Differences | Use Case |
|-------------|----------------|----------|
| **Proof of Concept** | Single-node, local-auth, minimal resources (8GB RAM) | Evaluation, demos |
| **Development/Test** | Multi-node, OAuth2, mock data generators, chaos testing | Feature development, QA |
| **Production** | Clustered databases, mTLS enforced, RBAC, HA configuration | Live operations |

**Architecture diagram:**

```
┌─────────────────────────────────────────────────────────────┐
│                         Ingress Layer                        │
│                  Nginx → Kong API Gateway                    │
└─────────────────────┬───────────────────────────────────────┘
                      │
         ┌────────────┴────────────┬──────────────┐
         ▼                         ▼              ▼
    ┌─────────┐             ┌──────────┐    ┌─────────┐
    │ Web UI  │             │ Core API │    │  SRQL   │
    │(Next.js)│             │  (gRPC)  │    │  Query  │
    └─────────┘             └────┬─────┘    └─────────┘
                                 │
                    ┌────────────┼────────────┐
                    ▼            ▼            ▼
              ┌──────────┐ ┌─────────┐ ┌──────────┐
              │   NATS   │ │ Proton  │ │ SPIFFE/  │
              │JetStream │ │   DB    │ │  SPIRE   │
              └──────────┘ └─────────┘ └──────────┘
                    ▲
       ┌────────────┼────────────┐
       │            │            │
   ┌───────┐   ┌────────┐   ┌────────┐
   │Poller │   │ Agent  │   │Checker │
   │(gRPC) │──▶│(mTLS)  │──▶│(Plugin)│
   └───────┘   └────────┘   └────────┘
                                 │
                                 ▼
                          Network Devices
```

#### Service Dependencies

**Core infrastructure:**

| Service | Purpose | Impact if Unavailable | HA Strategy |
|---------|---------|----------------------|-------------|
| **NATS JetStream** | Message broker, KV store | Data ingestion halted | 3-node cluster, R3 replication |
| **Timeplus Proton** | Stream processing DB | Queries fail, data buffered | OSS→Enterprise clustering upgrade |
| **Kong Gateway** | API gateway, auth | API access denied | Multiple replicas, shared cache |
| **SPIFFE/SPIRE** | Cert management | New pods fail auth | Server HA, agent per node |

**Data collection:**

```
Device → Checker (plugin) → Agent (proxy) → Poller (aggregator) → NATS → Core
```

- **Checkers**: SNMP, ICMP ping, iperf3 bandwidth tests, custom plugins
- **Agents**: Lightweight gRPC proxies, handle overlapping IP spaces
- **Pollers**: Data aggregators, chunking for large payloads

**External integrations:**

| Integration | Repository | Purpose |
|-------------|-----------|---------|
| Flowgger | https://github.com/awslabs/flowgger | High-performance syslog/GELF receiver |
| Risotto | https://github.com/nxthdr/risotto | IPAM and network visualization |
| GoFlow2+ | https://github.com/mfreeman451/goflow2 | NetFlow/IPFIX collection |
| ZenEngine | https://github.com/gorules/zen | Stateless business rule engine |

#### Identity and Access Management

**Authentication (current):**

| Method | Implementation | Status |
|--------|----------------|--------|
| **Local Auth** | Bcrypt-hashed passwords, CLI-generated | Production |
| **OAuth2/OIDC** | Google, Azure AD, Okta integration | Beta (Q4 2025) |
| **Service Identity** | SPIFFE X.509 SVIDs for workload auth | Production |

**Authorization:**

```json
{
  "tenant_id": "msp-customer-123",
  "roles": {
    "network-admin": {
      "permissions": [
        "read:devices",
        "write:devices",
        "read:metrics",
        "write:config"
      ]
    },
    "viewer": {
      "permissions": [
        "read:devices",
        "read:metrics"
      ]
    }
  }
}
```

**RBAC implementation:**
- JSON-based role definitions
- Stored in Kubernetes Secrets or config files (never in NATS KV for security)
- Tenant ID validation on every API call
- gRPC middleware validates mTLS certs + roles

**Multi-tenant isolation:**
- Tenant ID in JWT claims
- Database queries scoped: `WHERE tenant_id = $1`
- Network policies per tenant namespace (optional)
- Separate encryption keys per tenant (roadmap)

#### Sovereignty and Data Residency

| Requirement | Implementation |
|-------------|----------------|
| **Data Locality** | Deploy in specific regions, no data egress |
| **Edge Processing** | NATS hub/leaf topology for local aggregation |
| **No SaaS Dependencies** | Self-hosted, no phone-home |
| **Configurable Retention** | Per-tenant TTLs, customer-controlled purges |

**Compliance-ready features:**
- GDPR: Right to erasure, data export APIs
- CCPA: Data inventory, access logs
- PCI-DSS: Network segmentation, audit trails (roadmap)

#### High Availability

**Database tier:**

| Deployment | Configuration | Availability |
|------------|---------------|--------------|
| **OSS** | Single Proton instance + backups | 99.5% (planned downtime) |
| **Enterprise** | Timeplus Enterprise 3-node cluster | 99.9% |
| **Long-term Storage** | ClickHouse integration for historical data | 99.95% (managed) |

**Message broker:**
- NATS JetStream 3-node cluster with R3 replication
- Hub/leaf topology for geographic distribution
- Automatic failover and leader election

**API services:**
- Core API: Horizontal scaling (Q1 2026), shared state in NATS KV
- Stateless services (SRQL, Web): Load-balanced across replicas
- Kong Gateway: Multiple replicas with shared Redis cache

**Data collection:**
- Multiple poller instances per tenant
- Agent failover to backup pollers
- Erlang/BEAM distributed pollers (roadmap Q2 2026)

**Cross-region DR:**
- NATS hub/leaf federation across regions
- Database replication via ClickHouse
- Configuration backup in GitOps repository

#### Resource Requirements

**Production deployment (minimum):**

| Component | CPU | RAM | Storage | Scaling |
|-----------|-----|-----|---------|---------|
| **Timeplus Proton** | 4 cores | 8 GB | 60 GB | Vertical (CPU/RAM) |
| **NATS JetStream** | 2 cores | 8 GB | 60 GB | Vertical (RAM/disk) |
| **Core API** | 2 cores | 4 GB | 30 GB | Horizontal (replicas) |
| **Kong Gateway** | 1 core | 2 GB | 10 GB | Horizontal (replicas) |
| **Web UI** | 1 core | 1 GB | 5 GB | Horizontal (replicas) |
| **Poller** (per instance) | 1 core | 1 GB | 10 GB | Horizontal (instances) |
| **Agent** (per instance) | 0.5 core | 512 MB | 2 GB | Horizontal (instances) |
| **Supporting Services** | 0.5 core | 512 MB | 5 GB | Per service (Zen, OTEL, Flowgger) |

**Total minimum:** 12 cores, 25 GB RAM, 180 GB storage

**Scaling characteristics:**

| Load | Additional Resources |
|------|---------------------|
| **+10,000 devices** | +1 core, +2 GB RAM (Core API), +100 GB storage/month |
| **+1,000 events/sec** | +1 poller replica, +2 NATS cores |
| **+100 concurrent users** | +1 Web UI replica, +1 Kong replica |

**Reference configurations:**
- **Demo environment**: https://github.com/carverauto/serviceradar/tree/main/deployments/demo
- **Production example**: https://github.com/carverauto/serviceradar/tree/main/deployments/production

#### Storage Requirements

| Storage Type | Purpose | Performance | Backup |
|--------------|---------|-------------|--------|
| **Block Storage (PVC)** | NATS, Proton database | 1000+ IOPS, low latency | Daily snapshots |
| **Object Storage** | Config backups, SBOM | Standard | Versioned |
| **Ephemeral** | Logs, temp files | Local SSD | N/A |

**Supported storage:**
- **Kubernetes**: local-path, Longhorn, Rook/Ceph, cloud provider PVCs
- **Cloud**: AWS EBS, GCP Persistent Disk, Azure Managed Disk
- **On-premises**: Local disks, NFS, iSCSI, Ceph (optional)

**Retention examples:**

| Data Type | Default Retention | Storage Impact |
|-----------|------------------|----------------|
| **Metrics** | 90 days | 100 GB per 10k devices |
| **Logs** | 30 days | 50 GB per 10k devices |
| **Events** | 180 days | 20 GB per 10k devices |
| **Config History** | 1 year | 1 GB |

#### API Design

**Topology:**

```
Client → Nginx Ingress (TLS) → Kong Gateway (JWT) → Microservices
                                                    ├─ Core API (gRPC)
                                                    ├─ SRQL Query API
                                                    ├─ NATS KV API
                                                    └─ Auth API
```

**Primary endpoints:**

| Endpoint | Purpose | Protocol | Auth |
|----------|---------|----------|------|
| `/api/v1/devices` | Device CRUD | REST/JSON | JWT + RBAC |
| `/api/v1/query` | SRQL ad-hoc queries | REST/JSON | JWT + tenant scope |
| `/api/v1/metrics` | Metrics retrieval | REST/JSON | JWT + RBAC |
| `/api/v1/auth` | Authentication | REST/JSON | Basic or OAuth2 |
| `/api/v1/kv/*` | Configuration mgmt | REST/JSON | JWT + admin role |

**API conventions:**
- RESTful resource naming
- JSON request/response bodies
- RFC 7807 Problem Details for errors
- Pagination via `limit` and `cursor` parameters
- Rate limiting: 1000 req/min per user (configurable in Kong)

**SRQL Query Language:**

```sql
-- Example: Get top 10 devices by CPU usage
devices
  | where tenant_id = 'customer-123'
  | where cpu_usage > 80
  | sort by cpu_usage desc
  | limit 10
```

**API versioning:**
- Current: `/api/v1/`
- Future breaking changes: `/api/v2/`, `/api/v3/`
- Deprecation policy: 6-month notice, migration guides provided
- Sunset: Deprecated versions maintained for 12 months

**Documentation:**
- OpenAPI/Swagger: https://api.serviceradar.cloud/swagger
- SRQL Reference: https://docs.serviceradar.cloud/srql
- Authentication Guide: https://docs.serviceradar.cloud/auth

**Kubernetes integration (roadmap Q1 2026):**

```yaml
apiVersion: serviceradar.io/v1
kind: ServiceRadarTenant
metadata:
  name: customer-123
spec:
  displayName: "Acme Corp"
  rbacPolicy: "network-admin"
  retentionDays: 90
```

#### Release Process

**Versioning**: Semantic Versioning (SemVer) - MAJOR.MINOR.PATCH

**Release cadence:**

| Type | Frequency | Trigger |
|------|-----------|---------|
| **Major** (2.0.0) | Annually | Breaking API/architecture changes |
| **Minor** (1.1.0) | Monthly | New features, backward compatible |
| **Patch** (1.0.1) | As needed | Bug fixes, security updates |

**Release workflow:**
1. Tag `main` branch with version (e.g., `v1.0.53`)
2. GitHub Actions builds multi-arch container images
3. Images signed with Cosign and pushed to GHCR
4. Helm charts updated and published
5. Release notes auto-generated with changelog
6. Security advisories published if applicable

**Artifacts:**
- Container images: `ghcr.io/carverauto/serviceradar-*:v1.0.53`
- Helm charts: https://carverauto.github.io/helm-charts
- Binaries: GitHub Releases (amd64, arm64 for Linux, Darwin)
- SBOM: Attached to releases and embedded in images

**Quality gates:**
- All CI tests pass (unit, integration, e2e)
- Security scans show no critical/high CVEs
- At least 2 maintainer approvals
- Documentation updated

---

### Installation

#### Installation Methods

**Kubernetes (Recommended):**

```bash
# Add Helm repository
helm repo add serviceradar https://carverauto.github.io/helm-charts
helm repo update

# Install with default values
helm install serviceradar serviceradar/serviceradar --namespace serviceradar --create-namespace

# Install with custom values
helm install serviceradar serviceradar/serviceradar \
  --namespace serviceradar \
  --create-namespace \
  --set proton.resources.memory=16Gi \
  --set core.replicas=3
```

**Docker Compose (Evaluation):**

```bash
# Download compose file
curl -O https://raw.githubusercontent.com/carverauto/serviceradar/main/docker-compose.yml

# Start all services
docker compose up -d

# Verify services are running
docker compose ps
```

**Native Packages (Bare Metal):**

```bash
# Debian/Ubuntu
wget https://github.com/carverauto/serviceradar/releases/download/v1.0.53/serviceradar_1.0.53_amd64.deb
sudo dpkg -i serviceradar_1.0.53_amd64.deb
sudo systemctl start serviceradar

# RHEL/CentOS
wget https://github.com/carverauto/serviceradar/releases/download/v1.0.53/serviceradar-1.0.53.x86_64.rpm
sudo rpm -i serviceradar-1.0.53.x86_64.rpm
sudo systemctl start serviceradar
```

#### Installation Validation

**Automated health checks:**

```bash
# Kubernetes
kubectl get pods -n serviceradar
kubectl logs -n serviceradar -l app=serviceradar-core

# Test API endpoint
curl https://serviceradar.example.com/api/health

# Docker Compose
docker compose ps
curl http://localhost:8080/health
```

**Post-installation checklist:**

| Check | Command | Expected Result |
|-------|---------|----------------|
| All pods running | `kubectl get pods` | STATUS: Running |
| API responsive | `curl /health` | HTTP 200, `{"status":"healthy"}` |
| Database connected | Check Core logs | "Database connection established" |
| NATS cluster healthy | `nats server list` | All nodes connected |
| Web UI accessible | Open browser | Login page loads |
| SPIFFE certs issued | Check agent logs | "Certificate rotated successfully" |

**Initial configuration:**

```bash
# Create first admin user
kubectl exec -it serviceradar-tools -- serviceradar-cli user create \
  --username admin \
  --role admin \
  --tenant default

# Add first device for monitoring
curl -X POST https://serviceradar.example.com/api/v1/devices \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"hostname":"router1.example.com","ip":"192.168.1.1","snmp_community":"public"}'
```

**Troubleshooting common issues:**

| Issue | Cause | Solution |
|-------|-------|----------|
| Pods CrashLoopBackOff | Insufficient resources | Increase resource limits |
| Database connection timeout | PVC not bound | Check PVC status, storage class |
| 401 Unauthorized | JWT token expired | Regenerate token |
| SPIFFE cert errors | SPIRE agent not running | Verify SPIRE installation |

---

### Security

#### Security Self-Assessment

**Comprehensive assessment**: https://github.com/carverauto/serviceradar/blob/main/SECURITY_ASSESSMENT.md

**OpenSSF Best Practices Badge**: https://www.bestpractices.dev/en/projects/11310 (Currently Passing)

#### Cloud Native Security Tenets

**CNCF TAG-Security alignment:**

| Tenet | Implementation | Evidence |
|-------|----------------|----------|
| **Secure Defaults** | mTLS enforced, non-root containers, no default passwords | All services require explicit config |
| **Least Privilege** | RBAC per tenant, SPIFFE workload IDs, read-only filesystems | Service accounts scoped minimally |
| **Immutability** | Signed multi-stage Docker images, read-only root filesystems | Cosign signatures on all images |
| **Shift Left Security** | CodeQL SAST, Trivy container scans in CI | Automated pre-merge checks |
| **Transparency** | SBOM in releases, public security advisories | GitHub Security tab |

**Secure defaults (cannot be disabled in production):**
- mTLS between all microservices
- TLS 1.3 for external connections
- Bcrypt password hashing (14 rounds)
- JWT token expiration (1 hour)
- RBAC enforcement on all API calls

**Development mode (loosened security):**

For testing environments only, users can:
- Disable mTLS via Helm value `global.mTLS.enabled=false` (documented with warnings)
- Extend token expiration for debugging
- Use HTTP instead of HTTPS for local development

**Documentation**: https://docs.serviceradar.cloud/security/development-mode

#### Security Hygiene

**Frameworks and practices:**

| Practice | Tool/Process | Frequency |
|----------|-------------|-----------|
| **SAST** | GitHub CodeQL | Every commit |
| **Container Scanning** | Trivy | Every build |
| **Dependency Scanning** | Dependabot | Daily |
| **Secret Scanning** | GitHub Secret Scanning | Every commit |
| **Code Review** | 2-reviewer approval required | Every PR |
| **Signed Commits** | GPG signatures enforced | Every commit |
| **Penetration Testing** | Third-party audit | Annually (roadmap) |

**Security feature risk evaluation:**

High-risk features requiring ongoing maintenance:
- **Authentication mechanisms**: Local-auth, OAuth2 integration
- **RBAC policy engine**: Tenant isolation logic
- **SRQL query parser**: SQL injection prevention
- **mTLS certificate handling**: SPIFFE/SPIRE integration
- **API gateway configuration**: Kong security rules

**Risk mitigation:**
- Threat modeling for new features (STRIDE methodology)
- Security-focused code reviews for high-risk changes
- Automated regression tests for security controls
- Quarterly security retrospectives

#### Cloud Native Threat Modeling

**Principle of Least Privilege:**

| Component | Required Privileges | Justification |
|-----------|---------------------|---------------|
| **Core API** | Read/write database, pub/sub NATS, service coordination | Central orchestrator |
| **Pollers** | Write to NATS streams, read from agents | Data collection only |
| **Agents** | Network access for device polling | Minimal proxy, no data persistence |
| **Web UI** | Read-only API access | Writes proxied through server-side |
| **Database** | No external network access | Only accessible via Core API |

**Certificate rotation:**

| Certificate Type | Rotation Frequency | Automation | Monitoring |
|------------------|-------------------|------------|------------|
| **SPIFFE X.509 SVIDs** | 1 hour (configurable) | SPIRE automatic | Prometheus alert on expiration |
| **Kong JWT keys** | 30 days | Manual (automating Q1 2026) | Kong admin API checks |
| **TLS ingress certs** | 90 days (Let's Encrypt) | cert-manager | cert-manager metrics |

**Zero-downtime rotation:**
- SPIRE agent pre-fetches next certificate before expiration
- gRPC clients retry with new cert on TLS handshake failure
- Kong gracefully reloads configuration without dropping connections

**Secure Software Supply Chain:**

| Practice | Implementation | Compliance |
|----------|----------------|-----------|
| **SBOM Generation** | Syft (every build) | SPDX 2.3 format |
| **Image Signing** | Cosign (keyless via GitHub OIDC) | Sigstore |
| **Reproducible Builds** | Multi-stage Dockerfiles, pinned base images | Dockerfile linting |
| **Dependency Verification** | Go mod checksums, Cargo.lock | Lock files committed |
| **Vulnerability Scanning** | Trivy pre-release (blocks on high/critical) | CVE database |
| **Provenance** | SLSA Level 2 attestations | GitHub Actions provenance |

**Supply chain roadmap:**
- **Q1 2026**: SLSA Level 3 compliance
- **Q2 2026**: Binary reproducibility verification
- **Q3 2026**: Software transparency log integration

---

## Day 1 - Installation and Deployment Phase

### Project Installation and Configuration

**Standard installation flow (Kubernetes):**

1. **Prerequisites check**: Kubernetes 1.25+, Helm 3.8+, 25GB+ cluster resources
2. **Namespace creation**: `kubectl create namespace serviceradar`
3. **SPIRE installation** (if not present):
   ```bash
   helm install spire spiffe/spire --namespace spire-system --create-namespace
   ```
4. **Storage provisioning**: Verify default StorageClass or create PVCs manually
5. **Helm installation**:
   ```bash
   helm install serviceradar serviceradar/serviceradar -n serviceradar
   ```
6. **Initial configuration**:
   ```bash
   # Create admin user
   kubectl exec -it deploy/serviceradar-tools -n serviceradar -- \
     serviceradar-cli user create --username admin --role admin

   # Get generated password
   kubectl get secret serviceradar-admin -n serviceradar -o jsonpath='{.data.password}' | base64 -d
   ```
7. **Validation**: Access Web UI at `https://serviceradar.example.com` and log in

**Configuration touchpoints:**

| Configuration | Location | Format |
|--------------|----------|--------|
| **Helm values** | `values.yaml` | YAML |
| **Runtime config** | ConfigMaps | JSON/YAML |
| **Secrets** | Kubernetes Secrets | Base64-encoded |
| **RBAC policies** | Secrets (rbac-policies) | JSON |
| **Fleet config** | NATS KV (coming Nov 2025) | JSON |

### Project Enablement and Rollback

**Enabling ServiceRadar:**

```bash
# Fresh install
helm install serviceradar serviceradar/serviceradar -n serviceradar --create-namespace

# Upgrade existing installation
helm upgrade serviceradar serviceradar/serviceradar -n serviceradar
```

**Impact on cluster:**
- Installs resources in `serviceradar` namespace only
- Creates RBAC ClusterRoles for cross-namespace access (optional)
- Installs CRDs (coming Q1 2026): `ServiceRadarTenant`, `ServiceRadarDevice`
- No control plane downtime required
- No impact to existing workloads

**Disabling ServiceRadar:**

```bash
# Uninstall (retains PVCs by default)
helm uninstall serviceradar -n serviceradar

# Full cleanup including data
helm uninstall serviceradar -n serviceradar
kubectl delete pvc -n serviceradar --all
kubectl delete namespace serviceradar
```

**Downtime:** None for cluster, ServiceRadar services unavailable during uninstall

**Testing enablement/disablement:**
- CI/CD includes end-to-end lifecycle tests
- Tests cover: install → upgrade → rollback → uninstall
- Chaos engineering tests simulate partial failures during upgrades

**Resource cleanup:**

| Resource Type | Automatic Cleanup | Manual Steps |
|---------------|------------------|--------------|
| **Pods** | Yes (Helm hooks) | N/A |
| **Services** | Yes | N/A |
| **ConfigMaps/Secrets** | Yes | N/A |
| **PVCs** | No (data safety) | `kubectl delete pvc` if desired |
| **CRDs** | No (cluster-wide) | `kubectl delete crd serviceradartenant.serviceradar.io` |

### Rollout, Upgrade and Rollback Planning

**Kubernetes compatibility:**

| ServiceRadar Version | Kubernetes Versions | Testing Frequency |
|---------------------|---------------------|-------------------|
| 1.0.x | 1.25, 1.26, 1.27 | Monthly against new K8s releases |
| 2.0.x (future) | 1.27+ | Quarterly compatibility matrix |

**Upgrade procedures:**

```bash
# Standard upgrade (no downtime for data collection)
helm upgrade serviceradar serviceradar/serviceradar -n serviceradar

# Blue-green upgrade (zero-downtime for API)
kubectl create namespace serviceradar-v2
helm install serviceradar-v2 serviceradar/serviceradar -n serviceradar-v2
# Switch ingress, then delete old namespace
```

**Rollback procedures:**

```bash
# Helm rollback (automatic)
helm rollback serviceradar -n serviceradar

# Manual rollback (GitOps)
kubectl apply -f previous-version/manifests/
```

**Rollout/rollback failure scenarios:**

| Failure Type | Impact | Mitigation |
|--------------|--------|------------|
| **Database schema incompatibility** | Queries fail, data corruption risk | Manual migration rollback, restore from backup |
| **CRD version mismatch** | Operator fails to start | Delete CRD, reinstall compatible version |
| **Config format change** | Services crash loop | Helm rollback + manual config fix |
| **SPIFFE cert mismatch** | mTLS handshake failures | Restart SPIRE server, regenerate certs |

**Impact to running workloads:**
- Data collection: Brief interruption during poller restarts (<30s)
- API availability: No downtime with multiple replicas
- Database: Read-only mode during schema migrations

**Rollback trigger metrics:**

| Metric | Threshold | Action |
|--------|-----------|--------|
| API error rate | > 5% for 5 minutes | Automatic rollback |
| Database query latency | p99 > 5s for 10 minutes | Investigate, manual rollback |
| Pod crash loop | > 3 restarts in 5 minutes | Automatic rollback |
| Data collection success | < 95% for 15 minutes | Alert, manual decision |

**Upgrade testing matrix:**

| Test Path | Validation |
|-----------|-----------|
| v1.0.x → v1.1.0 | Forward compatibility, data integrity |
| v1.1.0 → v1.0.x | Rollback functionality, no data loss |
| v1.0.x → v1.1.0 → v1.0.x | Round-trip success |
| v1.0.x → v2.0.0 | Major version migration guide |

**Deprecation policy:**

| Change Type | Notice Period | Example |
|-------------|--------------|---------|
| **API endpoint removal** | 6 months | Deprecated endpoints return 410 Gone |
| **Config format change** | 3 months | Support both old and new formats during transition |
| **Feature removal** | 12 months | Feature flag to disable, then remove |
| **Breaking changes** | Documented in CHANGELOG | Bold text, migration guide provided |

**Alpha/Beta feature enablement:**

```yaml
# Helm values for experimental features
global:
  featureGates:
    alpha: true  # Enable all alpha features
    beta: true   # Enable all beta features

features:
  # Granular control
  aiOpsAnomalyDetection: alpha  # Opt-in
  advancedRbac: beta           # Opt-in
```

**Alpha/Beta guarantees:**
- No SLA or support commitments
- May change or be removed without deprecation notice
- Disabled by default in production Helm charts
- Clearly marked in documentation and UI

---

## Day 2 - Day-to-Day Operations Phase

### Scalability and Reliability

**Horizontal scaling:**

| Component | Scaling Method | Trigger | Max Recommended |
|-----------|---------------|---------|-----------------|
| **Pollers** | HPA (CPU:70%) | Kubernetes HPA | 100 instances per cluster |
| **Agents** | Manual/HPA | Device count | 1000 instances |
| **Core API** | HPA (CPU:80%) | Kubernetes HPA | 10 replicas (Q1 2026) |
| **Web UI** | HPA (requests) | Kubernetes HPA | 20 replicas |
| **Kong Gateway** | HPA (connections) | Kubernetes HPA | 10 replicas |

**Service Level Objectives (SLOs):**

| Metric | SLO | SLI | Measurement Window |
|--------|-----|-----|-------------------|
| **API Availability** | 99.9% | Pod healthy, /health returns 200 | 30 days |
| **API Latency** | p95 < 500ms | API request duration (Prometheus) | 5 minutes |
| **Data Collection Success** | 99.5% | Poller success rate | 24 hours |
| **Query Performance** | p95 < 500ms | SRQL query duration | 5 minutes |
| **Event Processing** | < 30s end-to-end | Ingest to query latency | 5 minutes |

**Resource usage scaling:**

| Additional Load | CPU Impact | Memory Impact | Storage Impact |
|----------------|-----------|---------------|----------------|
| +10k devices | +20% Core API | +2GB Core API | +100GB/month |
| +1k events/sec | +1 poller replica | +512MB per poller | +50GB/month |
| +100 concurrent users | +10% Web UI | +1GB Kong | Minimal |

**Resource exhaustion scenarios:**

| Exhaustion Type | Symptom | Prevention |
|-----------------|---------|------------|
| **PID limit** | "Cannot fork" errors | Reduce polling frequency, increase limits |
| **Socket exhaustion** | Connection refused | Increase `ulimit`, connection pooling |
| **Disk I/O** | High latency, timeouts | Rate limit ingestion, add IOPS |
| **Memory (OOM)** | Pod evictions | Increase limits, tune GC, add replicas |

**Load testing results:**

| Test Scenario | Result | Metrics |
|---------------|--------|---------|
| **50k devices, 1-min polls** | Success | 99.8% success rate, p95 latency 450ms |
| **10k events/sec** | Success | No data loss, 15s p99 processing delay |
| **5k concurrent API users** | Success | p95 latency 300ms, 0 errors |

**Testing tools:**
- k6 for API load testing
- Locust for user simulation
- Custom Python scripts for SNMP device simulation

**Recommended operational limits:**

| Limit | Value | Basis |
|-------|-------|-------|
| **Devices per cluster** | 100,000 | Load testing validated |
| **Pollers per cluster** | 100 | Network connection limits |
| **Events per second** | 10,000 | NATS throughput testing |
| **Concurrent API users** | 1,000 | Kong connection pooling |
| **Data retention (default)** | 90 days | Storage cost optimization |

**Resilience patterns:**

| Pattern | Implementation | Example |
|---------|----------------|---------|
| **Circuit Breaker** | gRPC clients fail-open after 5 consecutive failures | Poller → Agent connection |
| **Bulkhead** | Separate goroutine pools per tenant | Core API request handling |
| **Retry with Backoff** | Exponential backoff, max 5 attempts, 30s max delay | Database queries |
| **Timeout** | 30s for external calls, 10s for internal gRPC | All API calls |
| **Rate Limiting** | 1000 req/min per user (Kong) | API gateway |

### Observability Requirements

**Telemetry signals:**

| Signal | Format | Storage | Retention | Access |
|--------|--------|---------|-----------|--------|
| **Metrics** | Prometheus (OpenMetrics) | Prometheus TSDB | 7 days | Grafana dashboards |
| **Logs** | JSON (structured) | Timeplus Proton | 30 days | Web UI, CLI |
| **Traces** | OpenTelemetry (OTLP) | Jaeger | 7 days | Jaeger UI |
| **Profiles** | pprof | Ephemeral | N/A | Debug endpoints (disabled in prod) |

**Key metrics:**

```promql
# API request rate
rate(serviceradar_api_requests_total[5m])

# API latency (p95)
histogram_quantile(0.95, rate(serviceradar_api_duration_seconds_bucket[5m]))

# Device reachability
serviceradar_device_reachable_total / serviceradar_device_total

# Poller success rate
rate(serviceradar_poller_success_total[5m]) / rate(serviceradar_poller_attempts_total[5m])

# NATS message lag
nats_jetstream_stream_messages_pending
```

**Structured logging format:**

```json
{
  "timestamp": "2025-10-17T10:30:00Z",
  "level": "info",
  "service": "serviceradar-core",
  "tenant_id": "customer-123",
  "user_id": "admin@example.com",
  "action": "device.create",
  "resource_id": "device-456",
  "ip_address": "192.168.1.100",
  "message": "Device created successfully"
}
```

**Audit logging:**

All API mutations logged with:
- Timestamp (RFC 3339)
- User ID and tenant ID
- Action performed (create/update/delete/read)
- Resource affected (device, config, user)
- Source IP address
- Result (success/failure)

**Audit log storage:**
- Written to immutable NATS JetStream stream
- Replicated to Timeplus Proton for querying
- Retention: 1 year (configurable per compliance requirements)
- Export API available for SIEM integration

**Dashboards:**

**Pre-built Grafana dashboards:**
- Service health overview (availability, latency, error rate)
- Device monitoring status (reachability, metrics coverage)
- API performance metrics (throughput, latency distribution)
- Database and NATS health (query performance, storage usage)
- Security events (failed auth attempts, RBAC denials)

**Dashboard repository**: https://github.com/carverauto/serviceradar/tree/main/grafana-dashboards

**FinOps visibility:**

Exported metrics for cost tracking:
```promql
# Database storage consumption
serviceradar_proton_storage_bytes

# NATS message broker storage
nats_jetstream_storage_bytes

# Network egress (for cloud cost tracking)
serviceradar_network_egress_bytes_total

# Resource requests vs. actual usage
kube_pod_container_resource_requests{namespace="serviceradar"}
```

**Integration with cost tools:**
- Kubecost: Automatic discovery via namespace labels
- OpenCost: Prometheus metric compatibility
- Cloud provider billing: Tag resources with `app=serviceradar`

**Health monitoring:**

**Health endpoints:**
- `/health`: Liveness probe (returns 200 if process running)
- `/ready`: Readiness probe (returns 200 if dependencies available)
- `/healthz/detailed`: Extended health check with dependency status

**Health checks verify:**
- Database connectivity (Proton query succeeds)
- NATS JetStream cluster status (all nodes connected)
- SPIFFE certificate validity (not expired)
- Disk space availability (> 10% free)

**Determining usage:**

| Question | Method | Metric/Log |
|----------|--------|------------|
| Is ServiceRadar in use? | Prometheus | `serviceradar_devices_monitored > 0` |
| What's the device count? | API or UI | `/api/v1/devices/count` |
| Are pollers active? | Logs | "Polling cycle completed" messages |
| What's the data volume? | Prometheus | `serviceradar_metrics_collected_total` |

**Operator health verification:**

**Prometheus alerts:**
```yaml
# API error rate
- alert: HighAPIErrorRate
  expr: rate(serviceradar_api_errors_total[5m]) > 0.05
  for: 5m

# Poller failure rate
- alert: HighPollerFailureRate
  expr: rate(serviceradar_poller_failures_total[5m]) / rate(serviceradar_poller_attempts_total[5m]) > 0.05
  for: 10m

# Database query latency
- alert: SlowDatabaseQueries
  expr: histogram_quantile(0.99, rate(serviceradar_db_query_duration_seconds_bucket[5m])) > 5
  for: 10m

# Certificate expiration
- alert: CertificateExpiringSoon
  expr: (serviceradar_cert_expiry_seconds - time()) < 604800  # 7 days
```

### Dependencies

**Runtime service dependencies:**

| Service | Version | Purpose | Criticality |
|---------|---------|---------|-------------|
| **NATS JetStream** | v2.10+ | Message broker, KV store | Critical (data loss if down) |
| **Timeplus Proton** | v1.5+ | Stream processing database | Critical (queries fail) |
| **SPIFFE/SPIRE** | v1.8+ | Workload identity, mTLS | Critical (auth fails) |
| **Kong Gateway** | v3.4+ | API gateway | High (API access denied) |
| **Kubernetes** | 1.25+ | Orchestration | Critical (entire system) |

**Impact of unavailability:**

| Dependency Down | Immediate Impact | Mitigation | Recovery |
|-----------------|------------------|------------|----------|
| **NATS** | Data ingestion halted | Pollers buffer locally (5min) | Automatic retry, drain buffer |
| **Proton** | Queries fail, writes buffered | NATS retains messages | Replay from NATS on recovery |
| **SPIRE** | New pods fail auth | Existing services continue | Restart SPIRE, pods self-heal |
| **Kong** | API access denied | Direct Core API access possible | Restart Kong, routes restored |

**Dependency lifecycle policy:**

| Update Type | SLA | Process |
|-------------|-----|---------|
| **Security patches** | 7 days | Dependabot PR, automated tests, merge |
| **Minor updates** | 30 days | Monthly maintenance window |
| **Major updates** | 90 days | Quarterly planning, full regression testing |
| **EOL components** | 6 months before EOL | Replacement planned, tested, deployed |

**Source Composition Analysis (SCA):**

**Tools and frequency:**

| Tool | Scan Target | Frequency | Thresholds |
|------|------------|-----------|-----------|
| **Dependabot** | Go modules, npm, Cargo | Daily | Auto-merge low/medium |
| **Trivy** | Container images | Every build | Block on critical/high |
| **Snyk** | All dependencies | Weekly | Report only |
| **GitHub CodeQL** | Source code (SAST) | Every commit | Block on critical |

**Tracking and remediation:**

| Severity | Remediation SLA | Process |
|----------|----------------|---------|
| **Critical** | 7 days | Emergency patch, expedited review |
| **High** | 14 days | Priority fix, next patch release |
| **Medium** | 30 days | Scheduled for next minor release |
| **Low** | 90 days | Addressed opportunistically |

**Exceptions:**
- No patch available: Document mitigation, isolate affected component
- Breaking change required: Schedule for next major release, backport if critical

**SCA tracking dashboard**: GitHub Security tab shows all vulnerabilities and remediation status

### Troubleshooting

#### Component Failure Recovery

**Kubernetes API server failure:**
- **Impact**: No new deployments, existing pods continue running
- **Recovery**: ServiceRadar services unaffected, queue operations until API available
- **Testing**: Chaos engineering simulates API server downtime

**Database (Timeplus Proton) failure:**
- **Impact**: Queries fail, new data cannot be written
- **Recovery**:
  1. Pollers buffer data in NATS (automatic)
  2. Alert fires: "Database unreachable"
  3. Operator restarts database or restores from backup
  4. Core API drains NATS buffer and writes to database
- **Data loss**: None (NATS retains messages)

**NATS JetStream failure:**
- **Impact**: Data ingestion halted, configuration updates blocked
- **Recovery**:
  1. Pollers cache data locally (5-minute buffer)
  2. NATS cluster self-heals (leader election)
  3. Pollers reconnect automatically
  4. Cached data flushed to NATS
- **Data loss**: Minimal (5 minutes if all NATS nodes fail)

**SPIFFE/SPIRE failure:**
- **Impact**: New service instances cannot obtain certificates, existing services continue
- **Recovery**:
  1. Existing mTLS connections remain active
  2. Restart SPIRE server
  3. SPIRE agents reconnect
  4. New pods obtain certificates
- **Data loss**: None

**Leader node failure (etcd):**
- **Impact**: Kubernetes control plane briefly unavailable
- **Recovery**:
  1. Kubernetes elects new leader (automatic)
  2. ServiceRadar pods reschedule if on failed node
  3. Persistent data in PVCs preserved
- **Data loss**: None

#### Known Failure Modes

**1. Database Connection Pool Exhaustion**

| Field | Details |
|-------|---------|
| **Symptom** | API queries timeout, HTTP 503 errors, logs show "too many connections" |
| **Root Cause** | Core API connection pool too small for concurrent requests |
| **Resolution** | 1. Restart Core API pods<br>2. Increase `database.maxConnections` in Helm values<br>3. Scale Core API replicas horizontally |
| **Prevention** | Monitor `serviceradar_db_connections_active`, alert if > 90% of pool |

**2. NATS Stream Consumer Lag**

| Field | Details |
|-------|---------|
| **Symptom** | Delayed event processing, increasing `nats_jetstream_stream_messages_pending` |
| **Root Cause** | db-event-writer cannot keep up with ingestion rate |
| **Resolution** | 1. Scale db-event-writer replicas: `kubectl scale deployment serviceradar-db-event-writer --replicas=5`<br>2. Tune batch sizes: increase `writer.batchSize` in config<br>3. Check database write performance |
| **Prevention** | Alert on consumer lag > 10k messages, autoscale db-event-writer |

**3. SPIFFE Certificate Rotation Failure**

| Field | Details |
|-------|---------|
| **Symptom** | mTLS handshake failures, logs show "certificate expired", pod restarts |
| **Root Cause** | SPIRE agent unable to rotate certificates (network issue, SPIRE server down) |
| **Resolution** | 1. Verify SPIRE server health: `kubectl get pods -n spire-system`<br>2. Check SPIRE agent logs: `kubectl logs -n serviceradar <pod> -c spire-agent`<br>3. Manually trigger rotation: `kubectl exec <pod> -- spire-agent api fetch -socketPath /run/spire/sockets/agent.sock`<br>4. Restart affected pods if necessary |
| **Prevention** | Monitor `spiffe_cert_expiry_seconds`, alert if < 1 hour remaining |

**4. Poller-Agent Communication Failure**

| Field | Details |
|-------|---------|
| **Symptom** | Device data gaps, "unreachable" status in UI, logs show "connection refused" |
| **Root Cause** | Network connectivity issue, agent pod crash, mTLS certificate mismatch |
| **Resolution** | 1. Verify network connectivity: `kubectl exec <poller-pod> -- nc -zv <agent-service> 50051`<br>2. Check agent pod status: `kubectl get pods -l app=serviceradar-agent`<br>3. Validate mTLS: check SPIRE logs in both poller and agent<br>4. Restart agent pod if necessary |
| **Prevention** | Network policies correctly configured, regular connectivity tests |

**5. Large SNMP Payload Timeout**

| Field | Details |
|-------|---------|
| **Symptom** | Devices with many interfaces timeout, logs show "context deadline exceeded" |
| **Root Cause** | SNMP walk takes longer than 30s default timeout |
| **Resolution** | 1. Enable gRPC chunking in poller config<br>2. Increase timeout: `poller.snmpTimeout: 60s`<br>3. Use SNMP bulk requests: `snmp.useBulkRequests: true` |
| **Prevention** | Monitor `serviceradar_snmp_timeout_total`, tune timeouts per device type |

**Troubleshooting runbook**: https://docs.serviceradar.cloud/troubleshooting

### Compliance

#### Third-Party Code Attribution

**Attribution methods:**

| Method | Implementation | Example |
|--------|----------------|---------|
| **Source Files** | SPDX license identifiers in headers | `// SPDX-License-Identifier: Apache-2.0` |
| **Vendor Directories** | Original LICENSE files preserved | `vendor/github.com/nats-io/nats.go/LICENSE` |
| **Dependency Manifests** | Complete dependency lists | `go.mod`, `package.json`, `Cargo.toml` |
| **Build Artifacts** | SBOM embedded in container metadata | OCI image label `org.opencontainers.image.sbom` |

**CNCF Attribution Recommendations:**

**Direct incorporation (modified third-party code):**
```go
// Copyright 2023 ServiceRadar Authors
// Portions Copyright 2020 NATS.io (Apache-2.0)
// SPDX-License-Identifier: Apache-2.0
//
// This file includes modifications to github.com/nats-io/nats.go
```

**Unmodified third-party components:**
- Original LICENSE files retained in `vendor/` or `third_party/` directories
- No modifications to license headers

**Build artifacts (container images):**
```bash
# SBOM embedded in OCI image
docker inspect ghcr.io/carverauto/serviceradar-core:v1.0.53 | \
  jq '.[].Config.Labels["org.opencontainers.image.sbom"]'

# Extract SBOM
docker save ghcr.io/carverauto/serviceradar-core:v1.0.53 | \
  tar -xO --wildcards '*/layer.tar' | \
  tar -xO sbom.spdx.json
```

**Comprehensive attribution:**
- **ATTRIBUTION.md**: Complete list of dependencies with licenses
- **NOTICE**: Required notices for Apache 2.0 dependencies
- **LICENSE**: Primary project license (Apache 2.0)

**Repository**: https://github.com/carverauto/serviceradar/blob/main/ATTRIBUTION.md

### Security

#### Security Hygiene - Access Control

**Access control layers:**

| Layer | Mechanism | Enforcement Point |
|-------|-----------|------------------|
| **API Gateway** | Kong JWT validation, rate limiting | External traffic entry |
| **Service Mesh** | mTLS certificate validation | Every gRPC call |
| **RBAC Engine** | Tenant-scoped permission checks | Core API middleware |
| **Database** | Query scoping (`WHERE tenant_id = $1`) | Timeplus Proton |

**Policy enforcement:**

```go
// Example: RBAC middleware in Core API
func (m *RBACMiddleware) Intercept(ctx context.Context, req interface{}) error {
    // Extract tenant ID from JWT claims
    tenantID := extractTenantID(ctx)

    // Extract user roles
    roles := extractRoles(ctx)

    // Check if user has permission for action
    action := extractAction(req)
    if !m.policy.Allow(tenantID, roles, action) {
        return status.Error(codes.PermissionDenied, "insufficient permissions")
    }

    // Inject tenant ID into request for query scoping
    return injectTenantID(req, tenantID)
}
```

**Access control audit:**
- All API calls logged with user, tenant, action, result
- Failed authorization attempts trigger alerts
- Quarterly access review: remove unused accounts, audit permissions

#### Cloud Native Threat Modeling

**Security Response Team:**

**Current composition:**
- 3 core maintainers from different organizations
- 1 security-focused contributor (community)
- Rotating guest reviewer for major changes

**Diversity goals:**
- Geographic: North America, Europe, Asia
- Organizational: MSPs, telecom, security vendors
- Technical: Network ops, security engineers, platform engineers

**Rotation process:**

| Phase | Timeline | Activities |
|-------|----------|-----------|
| **Open Call** | Q1 each year | Blog post, Discord announcement, GitHub Discussion |
| **Nominations** | 2 weeks | Self-nominations or maintainer recommendations |
| **Selection** | 1 week | Maintainer consensus, evaluate contributions and security expertise |
| **Onboarding** | 2 weeks | Security response procedures, disclosure training, GPG key setup |
| **Term** | 2 years (renewable) | Active participation in security reviews and incident response |

**Selection criteria:**
- Demonstrated security expertise (CVEs found, security talks, certifications)
- Active contributions to ServiceRadar or related projects
- Commitment to response SLAs (48-hour acknowledgment)
- Diversity of perspective (organizational, technical, geographic)

**Security contact:**
- **Email**: security@serviceradar.cloud (forwards to security team)
- **PGP Key**: https://github.com/carverauto/serviceradar/blob/main/SECURITY.md
- **GitHub Security Advisories**: https://github.com/carverauto/serviceradar/security/advisories

---

## Summary and Next Steps

### Project Maturity

ServiceRadar is a production-ready, cloud-native network management platform currently deployed in MSP and telecommunications environments. The project demonstrates strong security fundamentals with comprehensive mTLS architecture, mature CI/CD practices, and active community engagement.

**Key strengths:**
- Carrier-grade scalability (100k+ devices validated through load testing)
- Security-first design (mTLS, RBAC, memory-safe languages)
- Cloud-native integration (Kubernetes, SPIFFE, CloudEvents, NATS, OpenTelemetry)
- Multi-tenant architecture suitable for MSP deployments

**Current limitations:**
- Helm chart maturity (ETA: Q4 2025)
- OAuth2 SSO integration (Beta: Q4 2025)
- Horizontal Core API scaling (Q1 2026)
- Kubernetes Operator pattern (Q1 2026)

### Roadmap Priorities

| Priority | Milestone | ETA |
|----------|-----------|-----|
| **Configuration Management** | NATS KV-based web UI config | November 2025 |
| **Authentication** | OAuth2/OIDC SSO integration | Q4 2025 |
| **Helm Maturity** | Production-ready Helm charts | Q4 2025 |
| **Kubernetes CRDs** | Operator pattern, custom resources | Q1 2026 |
| **Core API Scaling** | Horizontal scaling, shared state | Q1 2026 |
| **Carrier-Grade Testing** | 1M device load test | Q2 2026 |
| **Protocol Expansion** | gNMI streaming telemetry | Q2 2026 |
| **Compliance Certifications** | SOC 2 Type II | Q3 2026 |

### Getting Started

**For evaluators:**
```bash
# Quick start with Docker Compose
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
docker compose up -d
# Access Web UI at http://localhost:3000
```

**For production deployments:**
```bash
# Kubernetes installation
helm repo add serviceradar https://carverauto.github.io/helm-charts
helm install serviceradar serviceradar/serviceradar -n serviceradar --create-namespace
```

**For contributors:**
- **GitHub**: https://github.com/carverauto/serviceradar
- **Discord**: https://discord.gg/serviceradar
- **Docs**: https://docs.serviceradar.cloud
- **Contributing Guide**: https://github.com/carverauto/serviceradar/blob/main/CONTRIBUTING.md

### Support and Resources

| Resource | URL |
|----------|-----|
| **Documentation** | https://docs.serviceradar.cloud |
| **API Reference** | https://api.serviceradar.cloud/swagger |
| **Security Policy** | https://github.com/carverauto/serviceradar/security |
| **Community Forum** | https://github.com/carverauto/serviceradar/discussions |
| **Issue Tracker** | https://github.com/carverauto/serviceradar/issues |
| **Roadmap** | https://github.com/carverauto/serviceradar/blob/main/ROADMAP.md |
