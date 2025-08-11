# PRD: eBPF-based Application Profiler for ServiceRadar

**Author:** [Your Name]
**Date:** July 28, 2025
**Version:** 1.0

## 1. Introduction

### 1.1. Overview

This document outlines the requirements for integrating an **eBPF-based, on-demand application profiling service** into the **ServiceRadar** observability platform. This integration will enhance ServiceRadar's diagnostic capabilities by enabling developers and SREs to understand application-level performance issues through dynamic profiling with minimal overhead. By leveraging eBPF technology and implementing the service in Rust using the Aya framework, ServiceRadar will gain the ability to generate detailed flame graphs from live process data, providing deep insights into CPU utilization patterns and performance bottlenecks.

### 1.2. Problem Statement

Modern applications often experience transient performance issues that are difficult to diagnose. When ServiceRadar detects a CPU spike and identifies the responsible process, operators currently lack the tools to understand what that process is actually doing. Traditional profiling tools either require application restarts, introduce significant overhead, or provide insufficient detail about the actual code paths consuming resources.

Without proper profiling capabilities, teams resort to:
- Guesswork based on logs and metrics
- Time-consuming manual debugging sessions
- Reproduction attempts in non-production environments
- Over-provisioning resources to mask performance issues

This leads to longer incident resolution times, higher operational costs, and degraded user experience.

### 1.3. Goals

The primary goals of this integration are:

*   **Enable Deep Performance Analysis:** Provide operators with detailed visibility into application behavior during performance incidents without requiring application modifications.
*   **Minimize Performance Impact:** Use eBPF's low-overhead profiling capabilities to collect data without significantly affecting the target application.
*   **Integrate Seamlessly:** Leverage existing ServiceRadar infrastructure for command distribution and data collection.
*   **Provide Actionable Insights:** Generate industry-standard flame graphs that clearly show where applications spend their time.

## 2. User Personas

*   **Site Reliability Engineer (Sarah):** Sarah is on-call and receives an alert about high CPU usage on a production service. She needs to quickly understand what the service is doing to determine if this is expected behavior or a performance regression. She would use the profiler to generate a flame graph showing exactly which functions are consuming CPU time.

*   **Software Developer (David):** David's team deployed a new version of their service, and performance metrics show increased CPU usage. He needs to identify which code changes are responsible. The profiling capability would help him compare flame graphs before and after the deployment to pinpoint the problematic code paths.

*   **Platform Engineer (Elena):** Elena manages the observability infrastructure. She needs profiling tools that are safe to run in production, don't require special application builds, and integrate with existing monitoring workflows. The eBPF-based approach meets all these requirements.

## 3. Features & Requirements

### 3.1. eBPF-based Profiling Service

#### Description

A standalone service that uses eBPF to safely and efficiently collect stack traces from running processes. The service will be implemented in Rust using the Aya framework for its performance and safety guarantees.

#### Requirements

*   **Technology Stack:**
    *   Language: Rust
    *   eBPF Framework: Aya-rs
    *   Communication: gRPC
    *   Security: mTLS using existing ServiceRadar security framework

*   **Core Functionality:**
    *   Accept profiling requests via gRPC with parameters (PID, duration, frequency)
    *   Attach eBPF probes to kernel's `perf_event` subsystem
    *   Sample both user-space and kernel-space stack traces
    *   Aggregate stack traces in eBPF maps to minimize overhead
    *   Format results as folded stacks for flame graph generation
    *   Stream results back through existing poller infrastructure

*   **Performance Characteristics:**
    *   Sampling overhead: < 1% CPU impact on target process
    *   Memory usage: < 50MB for typical profiling session
    *   Startup time: < 100ms from request to first sample

*   **User Story:** As Sarah, when I see a CPU spike alert, I want to trigger profiling for the affected process and receive a flame graph within 30 seconds, so I can immediately understand what code is consuming resources.

### 3.2. Agent Integration

#### Description

Extend the existing ServiceRadar Agent to act as a proxy between the Poller and the new eBPF Profiler Service, maintaining the existing security and communication patterns.

#### Requirements

*   **New gRPC Endpoints:**
    *   `TriggerProfiling`: Initiate a profiling session
    *   Extended `StreamResults`: Handle profiler service type

*   **Configuration:**
    *   Add profiler service address to agent configuration
    *   Support for profiler service health checks

*   **Error Handling:**
    *   Graceful handling of profiler service unavailability
    *   Clear error messages for invalid PIDs or permission issues
    *   Timeout handling for long-running profiling sessions

*   **User Story:** As David, I want the profiling integration to reuse existing ServiceRadar authentication and authorization, so I don't need to manage separate credentials or access controls.

### 3.3. Poller Enhancement

#### Description

Update the Poller to support profiling as a new service type, enabling centralized control of profiling sessions across the fleet.

#### Requirements

*   **New Check Type:** Support `profiler` as a service type
*   **Command Distribution:** Ability to trigger profiling on specific hosts
*   **Result Collection:** Handle streaming of profiling results
*   **Session Management:** Track active profiling sessions and their status

*   **User Story:** As Elena, I want profiling to follow the same operational patterns as other ServiceRadar checks, so my team doesn't need to learn new procedures.

### 3.4. Data Format and Visualization Preparation

#### Description

Ensure profiling data is formatted correctly for standard flame graph visualization tools.

#### Requirements

*   **Output Format:** Folded stack format (e.g., `main;foo;bar 123`)
*   **Metadata:** Include timestamp, duration, sample count
*   **Streaming:** Support chunked data transfer for large profiles
*   **Compatibility:** Format compatible with popular flame graph tools

*   **User Story:** As a developer, I want to export profiling data in a standard format so I can use my preferred flame graph visualization tools.

## 4. Non-Functional Requirements

*   **Security:**
    *   All communication must use mTLS
    *   Profiling requires appropriate RBAC permissions
    *   No storage of sensitive application data

*   **Reliability:**
    *   Profiler service must not crash target applications
    *   Graceful degradation if eBPF is not available
    *   Automatic cleanup of profiling sessions

*   **Scalability:**
    *   Support concurrent profiling of multiple processes
    *   Efficient data streaming for large profiles
    *   Minimal impact on ServiceRadar core services

*   **Compatibility:**
    *   Support for Linux kernel 4.9+
    *   Initial focus on compiled languages (C/C++, Go, Rust)
    *   Clear documentation of limitations (e.g., JIT languages)

## 5. Rollout Plan

### Phase 1: Core Implementation

*   Implement eBPF Profiler Service in Rust
*   Define gRPC interfaces and protobuf schemas
*   Basic integration with Agent service
*   Manual testing on development environment
*   **Goal:** Demonstrate end-to-end profiling capability

### Phase 2: Agent and Poller Integration

*   Complete Agent proxy implementation
*   Add profiler support to Poller
*   Implement security and error handling
*   Integration testing across components
*   **Goal:** Enable profiling through standard ServiceRadar workflows

### Phase 3: Production Hardening

*   Performance optimization and testing
*   Comprehensive error handling
*   Documentation and runbooks
*   Limited production rollout
*   **Goal:** Production-ready profiling service

### Phase 4: Enhanced Capabilities

*   Support for additional runtime environments
*   Automated profiling triggers based on alerts
*   Historical profile storage and comparison
*   Integration with UI for visualization
*   **Goal:** Full-featured profiling platform

## 6. Success Metrics

*   **Time to Insight:** 80% reduction in time from CPU spike detection to root cause identification
*   **Adoption Rate:** 60% of high-CPU incidents use profiling within 3 months
*   **Performance Impact:** < 1% overhead confirmed in production environments
*   **Reliability:** 99.9% success rate for profiling requests
*   **User Satisfaction:** 4+ star rating from SRE and developer teams

## 7. Out of Scope

*   UI/frontend for triggering profiling and visualizing flame graphs (future phase)
*   Automatic profiling based on alerts (initial release is manual/API-driven)
*   Support for JIT-compiled runtimes without frame pointers (Java, Node.js)
*   Windows or macOS support
*   Integration with third-party APM tools