# General Technical Review questions
v1.0
## Introduction

The General Technical Review questions can be completed by a project in lieu of a presentation to a Technical Advisory Group (TAG) as well as to satisfy the Engineering Principle requirements of a Sandbox application or Due Diligence for moving levels.

The questions are designed to prompt **_design thinking_** for projects that would like to one day be a graduated project.

The intent is to understand how the project has adopted and aligned with the CNCF maturation levels as well as encourage good design & security best practices.


<!-- 
The General Technical Review questions can be completed by a project team in lieu of a presentation to a Technical Advisory Group (TAG) as well as to satisfy several of the Engineering Principle requirements for applying to CNCF Sandbox as well as applying to move to Incubation and Graduation.

For the purposes of the general technical review and further domain reviews, the questions are designed to prompt design thinking for ready-for-production projects and architecture. The intent is to understand and validate the cloud native software lifecycle of the project and whether it is in line with the CNCF Maturation process and levels. 

Project maintainers are expected to have designed the project for cloud native use cases and workloads, as well as taking a ‘secure by design and secure by default’ approach that enables adopters and consumers of the project the ability to ‘loosen’ the defaults in a manner that suits their environment, requirements and risk tolerance.

These questions are to gather knowledge about the project. Project maintainers are expected to answer to the best of their ability. **_Not every question will be addressable by every project._**

**Suggestion:** A recorded demo or diagram(s) may be easier to convey some of the concepts in the questions below. The project maintainers may provide a link to a recorded demo or add architectural diagrams along with your GTR questionnaire.

-->

### General Technical Review questions

The questions follow the cloud native software lifecycle day schemas:

**Day 0 - Planning Phase. (Sandbox)** - This phase covers design and architecture of the cloud native project.

**Day 1 - Installation and Deployment Phase (Incubation)** - This phase covers initial installation and deployment of the design developed during Day 0 - Planning Phase.

**Day 2 - Day-to-Day Operations Phase (Graduated)** - This phase covers post-deployment operations in production-ready environments to include monitoring, maintenance, auditing and troubleshooting.


### How to use this template

Make a copy of the template below and answer questions related to your project level to the best of your ability.
_**Not every question will be addressable or relevant to every project.**_
If this is the case for your project, please mark it as not-applicable (N/A) and provide a brief explanation.

**NOTE:** The questions are cumulative e.g. if you are applying for incubation or graduation, you should answer both day 0 and day 1 questions etc.

#### Tips

* Treat the GTR questionnaire as a living document and keep a copy of it in your project's own repo. The GTR questions are helpful to both contributors and users and will make updating it in the future less work when you want to apply to move levels.
* Answer more questions than the requirement for your level if it _makes sense for your project_. e.g. if you have documentation covering the different forms of observability in the Day-2 requirements.
* You **CAN** link out to your own project's documentation, but be sure to link to it in a _versioned_ form. e.g. link to it at a specific commit instead of the `main` branch, or versioned website.
* A recorded demo or diagram(s) may be easier to convey some of the concepts in the questions below. You may provide a link to a recorded demo or add architectural diagrams along with your GTR questionnaire.
* If you are unsure or have a question about any section below, **please ask**. Chances are you're not the only one with a question and the template should be updated with additional guidance.

---

# General Technical Review - ServiceRadar / Sandbox

- **Project:** ServiceRadar
- **Project Version:** 1.0.56
- **Website:** https://serviceradar.cloud
- **Date Updated:** 2025-11-22
- **Template Version:** v1.0
- **Description:** ServiceRadar provides SPIFFE-based, multi-protocol service and device monitoring with SRQL analytics backed by CNPG (database name `serviceradar`) and a Next.js web UI fronted by Kong.


## Day 0 - Planning Phase

### Scope

* Describe the roadmap process, how scope is determined for mid to long term features, as well as how the roadmap maps back to current contributions and maintainer ladder?  
  - Roadmap and release planning live in the Beads tracker with release notes in `CHANGELOG` and governance in `GOVERNANCE.md`; work is prioritized by user-impacting reliability/observability gaps and security requirements.
* Describe the target persona or user(s) for the project?  
  - Primary: platform/SRE/NOC teams operating fleets of Linux servers, appliances, and network gear; secondary: data/analyst users issuing SRQL queries.
* Explain the primary use case for the project. What additional use cases are supported by the project?  
  - Primary: service/device health monitoring via agents and pollers with SPIFFE identities and CNPG storage. Additional: SRQL analytics over timeseries/events, SNMP/syslog/flow ingestion, webhook alerting.
* Explain which use cases have been identified as unsupported by the project.  
  - Not an APM profiler, configuration manager, or general-purpose log lake; Proton is no longer used; no poller-ng.
* Describe the intended types of organizations who would benefit from adopting this project. (i.e. financial services, any software manufacturer, organizations providing platform engineering services)?  
  - Platform teams, MSPs, and regulated orgs needing workload identity and gRPC-based monitoring with on-prem CNPG.
* Please describe any completed end user research and link to any reports.  
  - Feedback captured in staging/production pilots and summarized in `docs/docs/onboarding-review-2025.md`.

### Usability

* How should the target personas interact with your project?  
  - Install via Helm or Docker Compose, operate via the Next.js web UI and `/api/*` endpoints behind Kong; automation uses gRPC/JSON APIs and KV overlays.
* Describe the user experience (UX) and user interface (UI) of the project.  
  - UI is a responsive Next.js app with authenticated dashboards and SRQL query tooling; see `docs/docs/web-ui.md`.
* Describe how this project integrates with other projects in a production environment.  
  - Integrates with CNPG (Postgres/Timescale), NATS JetStream for events, SPIRE for identity, OTEL for telemetry export, and Discord/webhook targets for alerts.

### Design

* Explain the design principles and best practices the project is following.  
  - Secure-by-default (SPIFFE mTLS, JWT auth through Kong), minimal dependencies, horizontally scalable stateless services, CNPG as the system of record, deterministic configs via KV overlays.
* Outline or link to the project’s architecture requirements? Describe how they differ for Proof of Concept, Development, Test and Production environments, as applicable.  
  - See `docs/docs/architecture.md`; POCs can run single-instance CNPG and one poller, while prod uses CNPG HA, multiple pollers/agents, Kong + JWKS, and OTEL collectors.
* Define any specific service dependencies the project relies on in the cluster.  
  - CNPG Postgres (`cnpg-rw` host, database `serviceradar`), NATS JetStream, SPIRE (Server/Agent), Kong, OTEL collector, optional Discord/webhook endpoints.
* Describe how the project implements Identity and Access Management.  
  - Workload identities via SPIFFE/SPIRE; user access via JWTs validated by Kong against Core JWKS; service-to-service gRPC secured by mTLS.
* Describe how the project has addressed sovereignty.  
  - All data persists in adopter-managed CNPG; no hosted Proton or third-party databases; outbound calls limited to configured webhooks/Discord.
* Describe any compliance requirements addressed by the project.  
  - SPDX SBOM and third-party attributions (`docs/LF/SBOM.spdx`, `docs/LF/third-party-deps.html`), signed releases via `scripts/cut-release.sh`, Dependabot updates, and secure transport defaults.
* Describe the project’s High Availability requirements.  
  - Run CNPG in HA mode, at least two pollers, and redundant OTEL collectors; services are stateless and can be scaled horizontally behind Kubernetes Services.
* Describe the project’s resource requirements, including CPU, Network and Memory.  
  - Pollers/agents are lightweight (sub-CPU core, sub-512Mi typical); Core/SRQL sized to CNPG throughput; OTEL sizing driven by trace volume; NATS sized to event throughput.
* Describe the project’s storage requirements, including its use of ephemeral and/or persistent storage.  
  - CNPG persistent volumes store all telemetry and registry data; services otherwise use ephemeral storage; no Proton volumes.
* Please outline the project’s API Design:  
    * Describe the project’s API topology and conventions  
      - REST/JSON behind Kong for user/API clients; gRPC for agents/pollers and internal services; SRQL exposed via `/api/query`.  
    * Describe the project defaults  
      - CNPG host `cnpg-rw`, database `serviceradar`, SPIFFE mTLS enabled, Kong enforces JWT, OTLP enabled to OTEL collector.  
    * Outline any additional configurations from default to make reasonable use of the project  
      - Configure ingress hostnames, JWKS issuer/audience, webhook endpoints, and CNPG credentials; adjust OTEL exporters per environment.  
    * Describe any new or changed API types and calls \- including to cloud providers \- that will result from this project being enabled and used  
      - No cloud-provider-specific APIs; relies on standard Postgres, OTLP, gRPC, and HTTPS.  
    * Describe compatibility of any new or changed APIs with API servers, including the Kubernetes API server  
      - Kubernetes used only for deployment; no custom CRDs are installed by default.  
    * Describe versioning of any new or changed APIs, including how breaking changes are handled  
      - Semantic versioning in `VERSION`/`CHANGELOG`; API changes announced in release notes; SRQL additions are backwards compatible, breaking changes require a major/minor bump.  
* Describe the project’s release processes, including major, minor and patch releases.  
  - Version bump + changelog update, `scripts/cut-release.sh` to tag and publish, Bazel builds push images, Helm chart updates follow, and (new) syft-based SPDX SBOM generation accompanies releases.

### Installation

* Describe how the project is installed and initialized, e.g. a minimal install with a few lines of code or does it require more complex integration and configuration?  
  - Helm chart (`helm/serviceradar`) with CNPG enabled by default, plus SPIRE, NATS, Kong, OTEL; Compose files exist for local dev; minimal config is CNPG credentials and ingress hosts.
* How does an adopter test and validate the installation?  
  - `helm upgrade --install --wait`, check pod readiness, hit `/healthz` on core/srql, verify agents connect, and run SRQL queries against CNPG via the UI/API.

### Security

* Please provide a link to the project’s cloud native [security self assessment](https://tag-security.cncf.io/community/assessments/).  
  - Not yet filed; current posture documented in `SECURITY.md` and `docs/docs/spiffe-identity.md`.
* Please review the [Cloud Native Security Tenets](https://github.com/cncf/tag-security/blob/main/community/resources/security-whitepaper/secure-defaults-cloud-native-8.md) from TAG Security.  
    * How are you satisfying the tenets of cloud native security projects?  
      - mTLS everywhere via SPIFFE, least-privilege service accounts, secure defaults on Helm (CNPG/TLS/Kong), SBOM + dependency updates.  
    * Describe how each of the cloud native principles apply to your project.  
      - Declarative configs (Helm/KV), automated identity bootstrapping (SPIRE), immutable container builds via Bazel, and observable OTEL signals.  
    * How do you recommend users alter security defaults in order to "loosen" the security of the project? Please link to any documentation the project has written concerning these use cases.  
      - Non-production may relax JWT audience/issuer checks and disable webhook signing; documented in `docs/docs/helm-configuration.md` and `docs/docs/kv-configuration.md`.  
* Security Hygiene  
    * Please describe the frameworks, practices and procedures the project uses to maintain the basic health and security of the project.  
      - Weekly Dependabot updates, reproducible builds, SBOM via syft (`docs/LF/SBOM.spdx`), repolinter checks (`docs/LF/repo_lint.md`), and CI lint/test workflows.  
    * Describe how the project has evaluated which features will be a security risk to users if they are not maintained by the project?  
      - SPIFFE/SPIRE, Kong authz, and CNPG credentials are treated as critical paths; defaults avoid Proton and external data sinks; secrets managed via Kubernetes secrets and Helm values.  
* Cloud Native Threat Modeling  
    * Explain the least minimal privileges required by the project and reasons for additional privileges.  
      - Services run as non-root, need network access to CNPG/NATS/OTEL/Kong; pollers/agents require only outbound gRPC; CNPG requires standard DB creds.  
    * Describe how the project is handling certificate rotation and mitigates any issues with certificates.  
      - SPIRE handles workload cert rotation; Kong/ingress certs follow Kubernetes secret rotation; JWKS keys exposed by Core for JWT validation.  
    * Describe how the project is following and implementing [secure software supply chain best practices](https://project.linuxfoundation.org/hubfs/CNCF_SSCP_v1.pdf)  
      - Immutable container images, provenance via Bazel builds, SBOM publishing, dependency updates via Dependabot, and signed release tags.



## Day 1 \- Installation and Deployment Phase

### Project Installation and Configuration

* Describe what project installation and configuration look like.  
  - `helm upgrade --install serviceradar ./helm/serviceradar -f values.yaml` with CNPG enabled; configure ingress hosts, CNPG credentials (database `serviceradar`), and SPIRE/Kong endpoints; agents/pollers point at core gRPC with SPIFFE IDs.

### Project Enablement and Rollback

* How can this project be enabled or disabled in a live cluster? Please describe any downtime required of the control plane or nodes.  
  - Enable via Helm values; disable components (e.g., Proton off, optional services scaled to zero) and uninstall via `helm uninstall`; core downtime only during DB unavailability.
* Describe how enabling the project changes any default behavior of the cluster or running workloads.  
  - Adds CNPG cluster, NATS, SPIRE, Kong ingress, OTEL collector, and service Deployments; no Kubernetes API changes.
* Describe how the project tests enablement and disablement.  
  - Helm `--wait` gating, pod readiness probes, and smoke SRQL queries; uninstall verified by absence of Deployments/Services and DB PVCs when removed.
* How does the project clean up any resources created, including CRDs?  
  - No CRDs installed; `helm uninstall` cleans Deployments/Services/ConfigMaps/Secrets; CNPG PVCs removed if storage class allows.

### Rollout, Upgrade and Rollback Planning

* How does the project intend to provide and maintain compatibility with infrastructure and orchestration management tools like Kubernetes and with what frequency?  
  - Helm chart maintained alongside releases; tested on current Kubernetes minor versions; Bazel images built for multi-arch.
* Describe how the project handles rollback procedures.  
  - Use `helm rollback` to prior revision; CNPG schema migrations are forward-compatible and guarded; services are stateless so rollbacks are safe if schema unchanged.
* How can a rollout or rollback fail? Describe any impact to already running workloads.  
  - Failures usually from CNPG connectivity or missing secrets; rollbacks can fail if schema breaks compatibility, so migrations are additive.
* Describe any specific metrics that should inform a rollback.  
  - Pod readiness failures, OTEL collector liveness, CNPG error rates, gRPC connection failures from pollers/agents.
* Explain how upgrades and rollbacks were tested and how the upgrade->downgrade->upgrade path was tested.  
  - Exercised in staging namespaces with Helm upgrades/rollbacks, validating KV SPIFFE connects and OTEL readiness before production.
* Explain how the project informs users of deprecations and removals of features and APIs.  
  - Release notes in `CHANGELOG`; helm values defaults updated (e.g., Proton disabled); docs updated in `docs/docs`.
* Explain how the project permits utilization of alpha and beta capabilities as part of a rollout.  
  - Feature flags and helm values gate experimental components; defaults are stable paths.

## Day 2 \- Day-to-Day Operations Phase

### Scalability/Reliability

* Describe how the project increases the size or count of existing API objects.  
  - Stateless services scale via replicas; pollers and agents are horizontally scaled; CNPG scales vertically and via HA.
* Describe how the project defines Service Level Objectives (SLOs) and Service Level Indicators (SLIs).  
  - Core API latency, poller job backlog, CNPG query latency, and OTEL export success are the primary SLIs; target SLOs tracked in staging dashboards (work-in-progress to formalize).
* Describe any operations that will increase in time covered by existing SLIs/SLOs.  
  - Bulk device backfills and SRQL long-range queries increase CNPG latency; monitor query duration and queue depth.
* Describe the increase in resource usage in any components as a result of enabling this project, to include CPU, Memory, Storage, Throughput.  
  - CNPG storage grows with telemetry; OTEL CPU rises with trace volume; pollers consume network toward agents proportional to check rate.
* Describe which conditions enabling / using this project would result in resource exhaustion of some node resources (PIDs, sockets, inodes, etc.)  
  - Excessive concurrent SRQL queries can exhaust CNPG connections; runaway OTLP exports can exhaust sockets if collectors are unreachable.
* Describe the load testing that has been performed on the project and the results.  
  - Staging tests cover multi-agent, multi-poller ingestion and SRQL query load; no formal public benchmark yet.
* Describe the recommended limits of users, requests, system resources, etc. and how they were obtained.  
  - Start with CNPG sized for expected ingest QPS and 2–3 pollers; increase OTEL collector replicas with sustained >70% CPU; keep CNPG connections below configured max_connections/2.
* Describe which resilience pattern the project uses and how, including the circuit breaker pattern.  
  - Client retries with backoff for CNPG/NATS, readiness/liveness probes, and Helm-driven rollbacks; no server-side circuit breaker yet.

### Observability Requirements

* Describe the signals the project is using or producing, including logs, metrics, profiles and traces. Please include supported formats, recommended configurations and data storage.  
  - Logs to stdout; Prometheus metrics via /metrics; OTLP traces/metrics exported to OTEL collector; CNPG stores events and timeseries for SRQL.
* Describe how the project captures audit logging.  
  - API access logged via Core/Kong; CNPG records data mutations; OTEL traces capture request context.
* Describe any dashboards the project uses or implements as well as any dashboard requirements.  
  - UI includes SRQL visualizations; operators can layer Prometheus/Grafana on OTEL exports; no bundled Grafana dashboards yet.
* Describe how the project surfaces project resource requirements for adopters to monitor cloud and infrastructure costs, e.g. FinOps  
  - Metrics include request rates, queue depth, and exporter failures; CNPG metrics expose storage and CPU utilization for cost tracking.
* Which parameters is the project covering to ensure the health of the application/service and its workloads?  
  - Pod readiness, CNPG connectivity, KV SPIFFE connection status, OTEL exporter success, poller-agent gRPC health, webhook delivery.
* How can an operator determine if the project is in use by workloads?  
  - Check active agent connections, poller job counts, and SRQL query metrics; CNPG ingest tables should show fresh writes.
* How can someone using this project know that it is working for their instance?  
  - Successful SRQL queries return recent device/service data; UI shows live status; no “transport error” logs from KV connections.
* Describe the SLOs (Service Level Objectives) for this project.  
  - Targeting >99% successful poll cycles and <1s Core API p95 in staging; formalized SLO doc pending.
* What are the SLIs (Service Level Indicators) an operator can use to determine the health of the service?  
  - Core/SRQL latency, poller backlog, CNPG query errors, OTEL export success, KV connectivity, webhook delivery success.

### Dependencies

* Describe the specific running services the project depends on in the cluster.  
  - CNPG Postgres (database `serviceradar`), NATS JetStream, SPIRE, Kong, OTEL collector; optional Discord/webhooks.
* Describe the project’s dependency lifecycle policy.  
  - Weekly Dependabot updates for Go/Rust/Actions; Bazel MODULE.lock maintained; Proton removed; poller-ng unused.
* How does the project incorporate and consider source composition analysis as part of its development and security hygiene? Describe how this source composition analysis (SCA) is tracked.  
  - SPDX SBOM regenerated via syft (`docs/LF/SBOM.spdx`), repolinter report (`docs/LF/repo_lint.md`), and third-party HTML (`docs/LF/third-party-deps.html`).
* Describe how the project implements changes based on source composition analysis (SCA) and the timescale.  
  - High/critical findings patched immediately; weekly cadence for routine updates; releases note dependency bumps.

### Troubleshooting

* How does this project recover if a key component or feature becomes unavailable? e.g Kubernetes API server, etcd, database, leader node, etc.  
  - Services retry CNPG/NATS/OTEL with backoff; pollers cache recent data; Helm rollbacks restore last-good revisions; SPIRE auto-rotates certs after outages.
* Describe the known failure modes.  
  - CNPG outages halt ingest; OTEL collector downtime buffers traces; missing secrets block pods; misconfigured SPIFFE IDs prevent KV connectivity.

### Compliance

* What steps does the project take to ensure that all third-party code and components have correct and complete attribution and license notices?  
  - SPDX SBOM and third-party HTML regenerated with syft; LICENSE present; repolinter identifies header gaps.
* Describe how the project ensures alignment with CNCF [recommendations](https://github.com/cncf/foundation/blob/main/policies-guidance/recommendations-for-attribution.md) for attribution notices.  
  <!--Note that each question describes a use case covered by the referenced policy document.-->  
    * How are notices managed for third-party code incorporated directly into the project's source files?  
      - Source files maintain upstream headers where provided; header gaps called out by repolinter.  
    * How are notices retained for unmodified third-party components included within the project's repository?  
      - Vendored artifacts keep original LICENSE/NOTICE files; SBOM lists package metadata.  
    * How are notices for all dependencies obtained at build time included in the project's distributed build artifacts (e.g. compiled binaries, container images)?  
      - SBOM generation will be automated in CI and attached to releases; build artifacts reference `docs/LF/SBOM.spdx`.

### Security

* Security Hygiene  
    * How is the project executing access control?  
      - Kong enforces JWT auth for UI/API; SPIFFE mTLS protects gRPC; CNPG credentials scoped per service; KV overlays gated by SPIFFE identities.
* Cloud Native Threat Modeling  
    * How does the project ensure its security reporting and response team is representative of its community diversity (organizational and individual)?  
      - Security contacts listed in `SECURITY.md` and `SECURITY_CONTACTS.md`; additional org maintainers added via governance process.  
    * How does the project invite and rotate security reporting team members?  
      - Maintainers manage contact rotation during release cycles; updates tracked in `SECURITY_CONTACTS.md` and release notes.
