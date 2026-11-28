## ADDED Requirements

### Requirement: One process accepts UDP syslog, TCP syslog, and OTLP
The log collector process SHALL accept UDP syslog and TCP syslog in one process when both listeners are configured, SHALL keep OTLP on that same process, and SHALL publish both syslog transports through one NATS output to the `events` stream on the subject `logs.syslog`.

A Flowgger configuration that contains only the primary `[input]` table SHALL keep running that single listener. Additional listeners SHALL be `[[inputs]]` entries that share `[output]`. Each extra listener SHALL use its own `type`, `listen`, `format`, and `framing`. `[input].rfc3164_timezone` SHALL apply to every listener. The process SHALL reconcile `events` once.

#### Scenario: UDP and TCP syslog share one publisher
- **WHEN** the collector starts with a UDP syslog listener and a TCP syslog listener
- **THEN** both listeners accept syslog
- **AND** both publish through the same NATS output to `logs.syslog` on `events`
- **AND** the process reconciles `events` once

#### Scenario: OTLP stays on the syslog process
- **WHEN** TCP syslog is enabled on the log collector
- **THEN** the OTLP listeners configured for that collector run in the same process
- **AND** the collector does not start a second process with OTEL disabled

#### Scenario: A single-input config is unchanged
- **WHEN** a Flowgger config contains `[input]` and no `[[inputs]]` entries
- **THEN** the collector runs that one listener and its output as it does today

#### Scenario: TCP syslog is disabled
- **WHEN** TCP syslog is not configured
- **THEN** the process does not bind a TCP syslog port
- **AND** each configured UDP syslog listener and OTLP listener still starts

#### Scenario: A listener cannot bind
- **WHEN** a configured listener cannot bind its address
- **THEN** the process exits
- **AND** the pod does not stay Ready

#### Scenario: Two listeners request the same socket
- **WHEN** two listeners in one config use the same input type and listen address
- **THEN** the process exits with an error that identifies the duplicate

### Requirement: The chart runs a single log-collector Deployment
The Helm chart SHALL run UDP syslog, TCP syslog, and OTLP in the `serviceradar-log-collector` Deployment. The chart SHALL NOT render a `serviceradar-log-collector-tcp` Deployment or a `serviceradar-log-collector-tcp-config` ConfigMap.

`logCollector.tcpCollector.enabled`, `listen`, `format`, and `framing` SHALL control the TCP listener on that Deployment. `logCollector.tcpCollector.replicaCount`, `resources`, and `streamReplicas` SHALL NOT create a second workload. The Deployment SHALL use `logCollector.replicaCount` and `logCollector.resources`, and its events-stream reservation SHALL be the log collector's single budgeted reservation. When `logCollector.tcpCollector.subject` is set to a value other than `logs.syslog`, chart render SHALL fail and the failure SHALL name that setting.

#### Scenario: Default render is one Deployment
- **WHEN** the chart renders with `logCollector.tcpCollector.enabled` left at its default
- **THEN** one log-collector Deployment is rendered
- **AND** its pods listen for UDP syslog, TCP syslog, and OTLP
- **AND** no Deployment named `serviceradar-log-collector-tcp` is rendered

#### Scenario: Disabling TCP removes the listener
- **WHEN** `logCollector.tcpCollector.enabled` is false
- **THEN** the log-collector pods do not listen for TCP syslog
- **AND** no `serviceradar-log-collector-tcp` Deployment is rendered

#### Scenario: Old TCP workload keys do not add pods
- **WHEN** `logCollector.tcpCollector.replicaCount`, `resources`, or `streamReplicas` is set
- **THEN** the chart still renders one log-collector Deployment
- **AND** that Deployment uses `logCollector.replicaCount` and `logCollector.resources`
- **AND** the events stream is reserved once

#### Scenario: A divergent TCP subject fails the render
- **WHEN** `logCollector.tcpCollector.subject` is set to a subject other than `logs.syslog`
- **THEN** chart render fails
- **AND** the error names `logCollector.tcpCollector.subject`

### Requirement: TCP syslog keeps a stable Service address
When TCP syslog is enabled, the `serviceradar-log-collector` Service SHALL expose UDP 514 and TCP 514, and the chart SHALL render a Service named `serviceradar-log-collector-tcp` that has no workload of its own. That compatibility Service SHALL select only `serviceradar-log-collector` pods labeled `serviceradar.io/syslog-tcp: "true"` and SHALL expose TCP 514. Pods that are not listening for TCP syslog SHALL NOT be endpoints of `serviceradar-log-collector-tcp`.

When an external Service is enabled, its UDP syslog port and its TCP syslog port SHALL be enabled independently, both SHALL select `serviceradar-log-collector` pods, and the chart SHALL NOT render `serviceradar-log-collector-tcp-external`. A TCP external Service that was enabled through `logCollector.tcpCollector.externalService` SHALL become the TCP port on the log-collector external Service. Different `loadBalancerIP` values on those two external Service blocks SHALL fail chart render.

#### Scenario: In-cluster clients reach both protocols on the primary Service
- **WHEN** TCP syslog is enabled
- **THEN** `serviceradar-log-collector` accepts connections on UDP 514 and TCP 514

#### Scenario: The previous TCP DNS name reaches listening pods
- **WHEN** a client connects to `serviceradar-log-collector-tcp` port 514
- **THEN** the connection is served by a `serviceradar-log-collector` pod listening for TCP syslog
- **AND** a pod that is not listening for TCP syslog is not an endpoint of that Service

#### Scenario: External UDP and TCP are separate ports of one Service
- **WHEN** the log-collector external Service is enabled and only its UDP syslog port is enabled
- **THEN** the external Service publishes UDP syslog
- **AND** it does not publish TCP syslog
- **AND** no Service named `serviceradar-log-collector-tcp-external` is rendered

#### Scenario: A former TCP load balancer uses the unified external Service
- **WHEN** `logCollector.tcpCollector.externalService.enabled` is true and the log-collector external Service has no separate pinned address
- **THEN** the log-collector external Service publishes TCP 514
- **AND** its selector is `serviceradar-log-collector`

### Requirement: Compose exposes both syslog transports on one service
The Docker Compose log-collector service SHALL publish host ports `514/udp` and `514/tcp` to the same container, and that container SHALL listen for both syslog transports.

#### Scenario: Compose has one log collector
- **WHEN** the Compose stack starts `log-collector`
- **THEN** that container listens for UDP syslog and TCP syslog
- **AND** the stack does not define a second log-collector service

### Requirement: Operator docs describe one collector
The published syslog ingest guide and the service port map SHALL describe TCP syslog as a listener on `serviceradar-log-collector`. They SHALL describe `serviceradar-log-collector-tcp` only as a compatibility Service that selects those same pods.

#### Scenario: The port map lists one collector
- **WHEN** an operator reads the service port map
- **THEN** syslog TCP is listed on `serviceradar-log-collector`
- **AND** `serviceradar-log-collector-tcp` is not described as a separate Deployment
