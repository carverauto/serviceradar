# General Technical Review - ServiceRadar / Sandbox

- **Project:** ServiceRadar
- **Project Version:** 1.0.53
- **Website:** https://serviceradar.cloud
- **Date Updated:** 2025-10-16
- **Template Version:** v1.0
- **Description:** ServiceRadar is an open-source network management and observability platform.


## Day 0 - Planning Phase

### Scope

* Describe the roadmap process, how scope is determined for mid to long term features, as well as how the roadmap maps back to current contributions and maintainer ladder?

Currently we are trying to work on foundational pieces that you would expect to find in any mature,
Network Management System (NMS) similar to what you would see in a commercial or opensource offering, such as Zabbix.

At the same time we are also trying to coalesce around an architecture that works where most traditional NMS systems fail, at carrier grade (100k+ devices).

Our roadmap currently centers around those two activities, while still trying to maintain enough stability to be used in production.

* Describe the target persona or user(s) for the project?

Telecom, Airline, Energy, IoT, Cyber Security organizations -- anyone managing large networks, ServiceRadar brings together network management and performance data, observability/APM, and SIEM into one place.

* Explain the primary use case for the project. What additional use cases are supported by the project?

-- Network Management and Observability, our secure by design platform is designed for cloud native environments, with easy deployments into kubernetes environments, microservices secured by mTLS and SPIFFE/Spire, built on top of a robust Event Driven Architecture using NATS JetStream and many other opensource and CNCF-related projects. Our poller/agent system allows users to deploy into far-reaching or overlapping IP space to securely monitor or collect data, processed by a lightweight, ClickHouse based stream processing engine. Users can easily create stateless rules using our upcoming rule editor (Zen Engine based), and deploy them from the web-ui. Easily configure and control fleets of agents/pollers/checkers using the NATS KV based configuration system. Golang, Rust, and OCaml are used extensively throughout the system, with most sensitive network facing systems written in Rust.

Addl:

Advanced AI Ops
Easily integrate data from point tools into a stream processing platform, on the edge or in the cloud
SIEM

* Explain which use cases have been identified as unsupported by the project.

TBD

* Describe the intended types of organizations who would benefit from adopting this project. (i.e. financial services, any software manufacturer, organizations providing platform engineering services)?

MSPs, IoT companies, Airlines, Energy Companies, Internet Companies, Telecom, etc -- anyone managing an on-prem, hybrid, or cloud computing or networking infra.

* Please describe any completed end user research and link to any reports.

N/A

### Usability

* How should the target personas interact with your project?

Install ServiceRadar using helm, k8s manifests, docker compose, or bare metal by accessing releases from the GitHub page.

* Describe the user experience (UX) and user interface (UI) of the project.

The k8s experience is by far the best installation and configuration experience, with docker being pretty good as well. Bare-metal is the most involved as you will have to use our internally developed tooling/scripts or documentation to generate mTLS certs for every service, deploy them, and configure microservices. Pollers communicate to Agents, agents talk to checkers (plugins) to perform monitoring actions, collections, or integrations. The poller communicates to the core. Depending on where you place these microservices, either all on one server or spread out according to your needs, your installation may be more involved.

Currently nearly all configuration is done through manually configuring .json files but we expect to switch over to our new KV based configuration system within the next 2-4 weeks. At that point nearly all management of the tool will happen through the web-ui, significantly improving UX.

Overall, the UI (web) experience is very good, the application is responsive, snappy, and designed with user accessibility considerations taken into account.

* Describe how this project integrates with other projects in a production environment.

ServiceRadar easily fits into kubernetes environments, but works well on bare metal as well. It was designed to be deployed en-masse, to support operators that may need fleets of agents/pollers, and for MSPs that might be managing multi-tenant environments with separate security domains and overlapping IP space.

For most NMS concerns, SNMP/syslog was standardized long ago and ServiceRadar can easily be configured to poll existing network infrastructure, or receive logging events.

### Design

* Explain the design principles and best practices the project is following.

ServiceRadar was designed from the ground up with security in mind. Secure protocols, software design, hardened languages, and security by default are the guiding principles.

We also wanted this to be able to handle large enterprise, carrier, or IoT networks suitable to manage 100k-1m+ devices/endpoints, while remaining fault tolerant and resilient to shifting network changes.

Our Event Driven and Service Oriented Architecture allow us to easily scale, while managing complexity.

* Outline or link to the project’s architecture requirements? Describe how they differ for Proof of Concept, Development, Test and Production environments, as applicable.

https://github.com/carverauto/serviceradar/tree/main/sr-architecture-and-design

* Define any specific service dependencies the project relies on in the cluster.

- SPIFFE/Spire for mTLS management
- nginx for ingress
- kong for API gateway (https://github.com/Kong/kong)
- timeplus proton stream processing database (https://github.com/timeplus-io/proton)
- flowgger (https://github.com/awslabs/flowgger)
- risotto (https://github.com/nxthdr/risotto)
- goflow2+ (https://github.com/mfreeman451/goflow2)
- NATS JetStream for message broker and KV (https://nats.io/)
- ZenEngine (https://github.com/gorules/zen)

* Describe how the project implements Identity and Access Management.

**Authentication**
We currently have a local-auth based system that is backed by `bcrypt` encrypted credentials, we're also near completion of adding support for oAuth2 clients to allow for SSO logins.

**Authorization**
RBAC system with JSON based rules, will be configurable only through config files or secrets in k8s. No RBAC information can be stored in the KV due to security concerns.

GRPC-based microservices are all secured via mTLS/TLS1.3 and RBAC'd as well.

* Describe how the project has addressed sovereignty.

TBD

* Describe any compliance requirements addressed by the project.

N/A

* Describe the project’s High Availability requirements.

OSS users can upgrade from the OSS TimePlus Proton to TimePlus Enterprise to get clustering capabilities if needed for the stream processing engine, and both versions of TimePlus databases integrate with ClickHouse for longer term storage needs.

Our new erlang/BEAM based distributed poller and agent architecture will allow us to offer a truely distributed platform.

Further work needs to be done to improve the Core API service so we can scale that out as well, in-cluster or across multiple clusters in different regions or availability zones if hosted in public cloud.

* Describe the project’s resource requirements, including CPU, Network and Memory.

- TimePlus proton DB - 8GB+ RAM, 60GB disc -- depends on retention policy/TTLs
- NATS JetStream - 8GB+ RAM, 60GB disc
- ServiceRadar Core - 4GB+ RAM, 30GB disc
- Other services/microservices - 500MB-1GB RAM

Project includes sample manifests from our live demo environment can serve as a guiding point for users looking for more resource requirements.

* Describe the project’s storage requirements, including its use of ephemeral and/or persistent storage.

PVC/local-path or public cloud storage is suitable, CEPH or advanced storage or networking is not required.

Persistent data store is required for NATS JetStream and TimePlus database.

* Please outline the project’s API Design:
    * Describe the project’s API topology and conventions
    * Describe the project defaults
    * Outline any additional configurations from default to make reasonable use of the project
    * Describe any new or changed API types and calls \- including to cloud providers \- that will result from this project being enabled and used
    * Describe compatibility of any new or changed APIs with API servers, including the Kubernetes API server
    * Describe versioning of any new or changed APIs, including how breaking changes are handled
* Describe the project’s release processes, including major, minor and patch releases.

### Installation

* Describe how the project is installed and initialized, e.g. a minimal install with a few lines of code or does it require more complex integration and configuration?
* How does an adopter test and validate the installation?

### Security

* Please provide a link to the project’s cloud native [security self assessment](https://tag-security.cncf.io/community/assessments/).
* Please review the [Cloud Native Security Tenets](https://github.com/cncf/tag-security/blob/main/community/resources/security-whitepaper/secure-defaults-cloud-native-8.md) from TAG Security.
    * How are you satisfying the tenets of cloud native security projects?
    * Describe how each of the cloud native principles apply to your project.
    * How do you recommend users alter security defaults in order to "loosen" the security of the project? Please link to any documentation the project has written concerning these use cases.
* Security Hygiene
    * Please describe the frameworks, practices and procedures the project uses to maintain the basic health and security of the project.
    * Describe how the project has evaluated which features will be a security risk to users if they are not maintained by the project?
* Cloud Native Threat Modeling
    * Explain the least minimal privileges required by the project and reasons for additional privileges.
    * Describe how the project is handling certificate rotation and mitigates any issues with certificates.
    * Describe how the project is following and implementing [secure software supply chain best practices](https://project.linuxfoundation.org/hubfs/CNCF\_SSCP\_v1.pdf)



## Day 1 \- Installation and Deployment Phase

### Project Installation and Configuration

* Describe what project installation and configuration look like.

### Project Enablement and Rollback

* How can this project be enabled or disabled in a live cluster? Please describe any downtime required of the control plane or nodes.
* Describe how enabling the project changes any default behavior of the cluster or running workloads.
* Describe how the project tests enablement and disablement.
* How does the project clean up any resources created, including CRDs?

### Rollout, Upgrade and Rollback Planning

* How does the project intend to provide and maintain compatibility with infrastructure and orchestration management tools like Kubernetes and with what frequency?
* Describe how the project handles rollback procedures.
* How can a rollout or rollback fail? Describe any impact to already running workloads.
* Describe any specific metrics that should inform a rollback.
* Explain how upgrades and rollbacks were tested and how the upgrade-\>downgrade-\>upgrade path was tested.
* Explain how the project informs users of deprecations and removals of features and APIs.
* Explain how the project permits utilization of alpha and beta capabilities as part of a rollout.

## Day 2 \- Day-to-Day Operations Phase

### Scalability/Reliability

* Describe how the project increases the size or count of existing API objects.
* Describe how the project defines Service Level Objectives (SLOs) and Service Level Indicators (SLIs).
* Describe any operations that will increase in time covered by existing SLIs/SLOs.
* Describe the increase in resource usage in any components as a result of enabling this project, to include CPU, Memory, Storage, Throughput.
* Describe which conditions enabling / using this project would result in resource exhaustion of some node resources (PIDs, sockets, inodes, etc.)
* Describe the load testing that has been performed on the project and the results.
* Describe the recommended limits of users, requests, system resources, etc. and how they were obtained.
* Describe which resilience pattern the project uses and how, including the circuit breaker pattern.

### Observability Requirements

* Describe the signals the project is using or producing, including logs, metrics, profiles and traces. Please include supported formats, recommended configurations and data storage.
* Describe how the project captures audit logging.
* Describe any dashboards the project uses or implements as well as any dashboard requirements.
* Describe how the project surfaces project resource requirements for adopters to monitor cloud and infrastructure costs, e.g. FinOps
* Which parameters is the project covering to ensure the health of the application/service and its workloads?
* How can an operator determine if the project is in use by workloads?
* How can someone using this project know that it is working for their instance?
* Describe the SLOs (Service Level Objectives) for this project.
* What are the SLIs (Service Level Indicators) an operator can use to determine the health of the service?

### Dependencies

* Describe the specific running services the project depends on in the cluster.
* Describe the project’s dependency lifecycle policy.
* How does the project incorporate and consider source composition analysis as part of its development and security hygiene? Describe how this source composition analysis (SCA) is tracked.
* Describe how the project implements changes based on source composition analysis (SCA) and the timescale.

### Troubleshooting

* How does this project recover if a key component or feature becomes unavailable? e.g Kubernetes API server, etcd, database, leader node, etc.
* Describe the known failure modes.

### Compliance

* What steps does the project take to ensure that all third-party code and components have correct and complete attribution and license notices?
* Describe how the project ensures alignment with CNCF [recommendations](https://github.com/cncf/foundation/blob/main/policies-guidance/recommendations-for-attribution.md) for attribution notices.
  <!--Note that each question describes a use case covered by the referenced policy document.-->
    * How are notices managed for third-party code incorporated directly into the project's source files?
    * How are notices retained for unmodified third-party components included within the project's repository?
    * How are notices for all dependencies obtained at build time included in the project's distributed build artifacts (e.g. compiled binaries, container images)?

### Security

* Security Hygiene
    * How is the project executing access control?
* Cloud Native Threat Modeling
    * How does the project ensure its security reporting and response team is representative of its community diversity (organizational and individual)?
    * How does the project invite and rotate security reporting team members?
