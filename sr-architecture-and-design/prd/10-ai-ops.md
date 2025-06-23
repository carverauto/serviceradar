# PRD: AIOps Capabilities for ServiceRadar with DeepCausality

**Author:** [Michael Freeman]
**Date:** June 22, 2025
**Version:** 1.3 (Expanded Data Source and System-Theoretic Alignment)

## 1. Introduction

### 1.1. Overview

This document outlines the requirements for integrating the **[DeepCausality](https://deepcausality.com/docs/intro/)** library into the **ServiceRadar** network management application. This integration will transform ServiceRadar from a traditional monitoring system into a sophisticated AIOps platform. Inspired by the evolution of SRE and the principles of System-Theoretic Accident Model and Processes (STAMP), this project moves beyond analyzing linear failure chains to building a system that understands and manages complex interactions, enforces safety constraints, and provides automated control. By leveraging hyper-geometric computational causality, ServiceRadar will gain the ability to perform advanced root cause analysis (RCA), detect system-level hazard states, and provide actionable, context-aware insights to operators, thereby significantly reducing downtime and operational overhead.

### 1.2. Problem Statement

Modern IT environments are complex and distributed. When a service fails, identifying the root cause is a time-consuming and often manual process of sifting through logs, metrics, and events from disparate systems. ServiceRadar currently excels at *detecting* failures but lacks the capability to *diagnose* their underlying causes automatically.

Operators are inundated with alerts, many of which are symptoms of a single root problem, leading to alert fatigue. Furthermore, the current system is reactive; it reports issues only after they have occurred. This leads to longer Mean Time to Resolution (MTTR) and impacts service availability.

### 1.3. Goals

The primary goals of this integration are:

*   **Reduce Mean Time to Resolution (MTTR):** Automatically identify the root cause of service failures, enabling operators to fix problems faster.
*   **Decrease Alert Noise:** Correlate related events and suppress symptomatic alerts, presenting operators with a single, actionable root cause alert.
*   **Enable Proactive Monitoring:** Shift from a reactive to a predictive monitoring model by identifying patterns that signal impending failures.
*   **Enhance Operator Efficiency:** Provide clear, contextual, and causal explanations for incidents, reducing the need for manual investigation.

## 2. User Personas

*   **DevOps Engineer / SRE (Alice):** Alice is responsible for maintaining the reliability and uptime of production services. She needs to quickly diagnose and resolve incidents. She would use the new AIOps features to understand why a service went down without having to manually correlate data from multiple dashboards.
*   **Network Administrator (Bob):** Bob manages the network infrastructure. When an application team reports a problem, he needs to determine if it's a network issue. The causal analysis would help him immediately see if network performance degradation is the root cause of an application failure.
*   **IT Manager (Carol):** Carol oversees the IT operations team. Her goal is to improve operational efficiency and reduce downtime. The predictive capabilities and reduced MTTR directly contribute to her KPIs.

## 3. Features & Requirements

### 3.1. Advanced RCA as Causal Analysis

#### Description

When a service failure is detected, ServiceRadar will use DeepCausality to analyze data from multiple sources. Instead of identifying a single "root cause," the system will identify the inadequately controlled interactions between system components that led to the loss. The multi-context capability of DeepCausality is key to this feature.

#### Requirements

*   **Multi-Context Data Modeling:** The ServiceRadar Core Service will feed data into separate DeepCausality contexts:
    *   **Network Context:** A comprehensive view of network health and state, incorporating data from multiple sources:
        *   **Performance Telemetry:** Active measurements from `rperf` (latency, jitter, loss) and passive data from SNMP collections and gNMI streaming telemetry.
        *   **Network Events:** Asynchronous notifications such as SNMP traps and high-priority syslog events indicating state changes (e.g., link down, BGP neighbor change).
        *   **Reachability and Topology Data:** Insights from ICMP ping sweeps, network discovery sweeps, and BGP routing data.
    *   **Host Context:** Agent data (process status, CPU/memory usage, port availability).
    *   **Configuration & Inventory Context:** A model of the intended state of the network and services. This context will be populated by the ServiceRadar Sync Service, which integrates with external sources of truth, including:
        *   **IPAM and DCIM platforms:** such as NetBox, providing device roles, IP information, and physical/virtual topology.
        *   **Network Configuration Management (NCM) platforms:** such as OpenText Network Automation, providing data on recent configuration pushes, compliance status, and detected config drift.
    *   **Control/Feedback Context:** A model of service dependencies and control loops (e.g., Web UI -> Core API -> Proton DB; Quota Rightsizer -> Monitoring Feedback -> Quota Service).
*   **Hypergraph-based Topology:** The relationships between components across different contexts will be modeled as a **hypergraph**. This allows the system to represent both simple dependencies (`A -> B`) and complex, multi-factor causal events `(A + B + C) -> D`, which is critical for accurately modeling real-world failure domains.
*   **Deterministic Causal Model Execution:** Upon detecting a service failure, the Core Service will trigger a causal analysis model based on **pre-defined, deterministic rules.**
*   **Enriched Alerting:** The resulting alert will be enriched with the identified **causal scenario**.
    *   **Example Alert:** "Service 'Web-UI' is down. **Causal Scenario:** An unsafe control action occurred. The quota rightsizer reduced the web server's memory quota based on incorrect usage feedback, leading to resource starvation."
*   **User Story:** As Alice, when I receive an alert that the payment gateway is down, I want the system to tell me that the cause was an unsafe interaction between the automated deployment system and the database configuration service, so I don't waste time just blaming one component.

### 3.2. Hazard State Detection (Predictive Analysis)

#### Description

Leverage DeepCausality to identify **system-level hazard states**—conditions where the system is vulnerable to an accident, but a loss has not yet occurred. This provides operators a window of opportunity to intervene proactively.

#### Requirements

*   **Temporal Pattern Recognition:** The system will analyze time-series data from the Proton database to build causal models of **known hazard states.**
*   **Predictive Alerting:** When a known hazard state is detected, a new type of "Hazard" or "Pre-Failure" alert will be generated.
    *   **Example Alert:** "**HAZARD DETECTED:** Service 'API-Gateway' has entered a hazardous state. Memory usage is steadily increasing while response latency is degrading. **This condition, if left unmitigated, will lead to a service failure.**"
*   **Configurable Models:** Provide a mechanism (e.g., a JSON configuration) to define the causaloids or patterns that constitute a hazard state.
*   **User Story:** As Bob, I want to be notified when the network has entered a hazard state (e.g., a backup fiber link has failed, but the primary is still active), so I can fix the redundancy issue before the primary link has a problem.

### 3.3. Causal Graph Visualization

#### Description

Provide a user interface within the ServiceRadar Web UI to visualize the chain of causal events that led to an incident.

#### Requirements

*   **Timeline View:** Display a timeline of events leading up to and including the failure.
*   **Graph Visualization:** For a given incident, render a directed **(hyper)graph** showing the nodes (services, hosts, configurations) and edges (causal relationships) that connect the root cause to the final symptom. **The visualization must be capable of showing multiple events contributing to a single effect.**
*   **Interactive Exploration:** Allow users to click on nodes in the graph to see detailed metrics and logs for that component at that point in time.
*   **Integration with Alerts:** Alerts in the dashboard should link directly to the causal graph visualization for that incident.
*   **User Story:** As Alice, after seeing a root cause alert, I want to view a graph that visually explains the connection between a code deployment, a subsequent database slowdown, and the eventual application timeout.

### 3.4. Automated Remediation via Causal State Machine

#### Description
This feature introduces a **control layer** that connects causal inference to automated action. By defining a state machine driven by causal events, ServiceRadar will be able to not only diagnose problems but also **enforce safety constraints** by triggering automated remediation workflows, preventing **Unsafe Control Actions (UCAs)** or mitigating their effects.

#### Requirements
*   **Causal State Machine Definition:** Provide a configuration file (e.g., YAML) where users can define states for a service (e.g., `Normal`, `Hazardous`, `Loss`, `Remediating`).
*   **Inference-to-State Mapping:** Allow users to map causal inferences or detected hazard states from DeepCausality to specific state transitions. (e.g., Hazard State `MemoryLeakDetected` -> transition to `Hazardous` state).
*   **State-to-Action Mapping:** Allow users to associate a **control action** with each state entry. Actions could include:
    *   Executing a local script.
    *   Calling a webhook (e.g., to trigger an Ansible Tower job).
    *   **Blocking a detected Unsafe Control Action.**
    *   Creating a ticket in a system like Jira.
*   **User Story:** As an SRE, when the system detects that our automated quota rightsizer is about to perform an Unsafe Control Action (based on bad feedback), I want the Causal State Machine to immediately place the rightsizer in a "Paused-Hazardous" state and alert a human for review, preventing a production outage.

## 4. Non-Functional Requirements

*   **Performance:** Causal analysis should complete within seconds of a detected failure to ensure timely alerting. The overhead of running the DeepCausality library should not significantly impact the performance of the Core Service.
*   **Scalability:** The system must be able to handle causal analysis for thousands of monitored services and devices across hundreds of hosts.
*   **Extensibility:** Adding new contexts or causal models should be possible through configuration without requiring a full system re-architecture.
*   **Accuracy:** The RCA models should have a high degree of precision and recall to ensure operator trust. The system must provide a mechanism for feedback to improve the models over time (future release).

## 5. Rollout Plan

### Phase 1: Backend Integration & Causal Analysis

*   Integrate the DeepCausality library into the ServiceRadar Core Service.
*   Implement the multi-context data ingestion pipeline, **modeling the system's control loops and topology as a hypergraph.**
*   Develop the first set of deterministic causal models for **analyzing component interactions.**
*   Implement enriched alerting via webhooks.
*   **Goal:** Deliver initial causal analysis capabilities to a select group of internal users.

### Phase 2: Hazard State Detection & Model Expansion

*   Develop and deploy predictive failure models focused on **detecting known system hazard states.**
*   Introduce the "Hazard Detected" alert type.
*   Expand the library of causal models to cover more complex scenarios.
*   **Goal:** Enable proactive monitoring by giving operators time to act before a loss occurs.

### Phase 3: UI Visualization & General Availability

*   Develop the Causal Graph Visualization component in the Web UI.
*   Integrate the visualization with the alerting system.
*   Refine models based on feedback from earlier phases.
*   **Goal:** Make the full AIOps feature set available to all users.

### Phase 4: Automated Remediation & Control Enforcement

*   **Implement the Causal State Machine and control layer within the Core Service.**
*   **Build the configuration interface for defining states and control actions.**
*   **Integrate with common automation tools to enforce safety constraints and remediate hazard states.**
*   **Goal: Enable a closed-loop system that can actively prevent outages, not just report on them.**

## 6. Success Metrics

*   **Mean Time to Resolution (MTTR):** A reduction of at least 30% in the average time from incident detection to resolution.
*   **Alert Noise Reduction:** A 50% or greater reduction in the total number of alerts generated for a single incident.
*   **Predictive Alert Success Rate:** At least 70% of predictive alerts are confirmed to be valid potential incidents by operators.
*   **User Adoption:** The percentage of incidents where operators use the causal analysis features to guide their response.
