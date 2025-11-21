# ServiceRadar Gleam Poller Architecture

## Overview

The ServiceRadar Gleam Poller follows a clear separation of concerns for communication patterns:

```
┌──────────┐     GenServer/Actor     ┌─────────┐      gRPC        ┌──────────────┐
│  Poller  │ ◄──────────────────────► │  Agent  │ ◄───────────────► │   External   │
│          │                          │         │                   │   Checkers/  │
│          │                          │         │                   │   Plugins    │
└──────────┘                          └─────────┘                   └──────────────┘
     │                                                                  (Go, Rust,
     │                                                                   Python, etc)
     │ gRPC
     ▼
┌──────────────┐
│ Core Service │
└──────────────┘
```

## Communication Patterns

### 1. Poller ↔ Agent Communication (Internal)
- **Protocol**: GenServer/Actor messages (Erlang/OTP)
- **Module**: `poller/agent_coordinator.gleam`
- **Purpose**: Internal communication between Gleam components
- **Benefits**:
  - Low latency
  - Built-in supervision and fault tolerance
  - Native to the BEAM VM

### 2. Poller → Core Service Communication
- **Protocol**: gRPC over HTTP/2
- **Module**: `poller/core_service.gleam`
- **Purpose**: Report aggregated service statuses to the central system
- **Implementation**: Uses protozoa for protobuf encoding/decoding

### 3. Agent → External Checkers/Plugins Communication
- **Protocol**: gRPC over HTTP/2
- **Module**: `poller/external_checker_client.gleam`
- **Purpose**: Execute health checks via external services written in other languages
- **Use Cases**:
  - HTTP health checks (Go checker)
  - Database connectivity tests (Rust checker)
  - Custom business logic checks (Python plugins)

## Module Responsibilities

### `poller.gleam`
- Main entry point and orchestrator
- Manages the polling loop
- Coordinates agents and core service reporting

### `poller/agent_coordinator.gleam`
- Manages agent lifecycle (start, stop, restart)
- Implements circuit breaker pattern for fault tolerance
- Uses GenServer/Actor model for agent communication
- Handles agent failures and recovery

### `poller/core_service.gleam`
- gRPC client for communicating with the core service
- Handles batch reporting of service statuses
- Implements streaming for large datasets
- Uses protobuf for message encoding

### `poller/external_checker_client.gleam`
- gRPC client for agents to communicate with external checkers
- Supports various checker types (HTTP, TCP, database, custom)
- Language-agnostic interface for plugins

### `poller/simple_supervisor.gleam`
- Implements basic supervision strategies
- Handles agent restarts on failure
- Manages poller lifecycle

## Data Flow

1. **Polling Cycle Starts**: Poller initiates a check cycle
2. **Agent Activation**: Poller sends check requests to agents via GenServer messages
3. **External Checking**: Agents call external checkers via gRPC
4. **Result Collection**: Agents return results to poller via GenServer messages
5. **Aggregation**: Poller aggregates all service statuses
6. **Reporting**: Poller reports to core service via gRPC

## Error Handling

- **Circuit Breaker**: Prevents cascading failures by temporarily disabling failed agents
- **Supervision Tree**: Automatic restart of failed components
- **Timeout Management**: Configurable timeouts for all external calls
- **Graceful Degradation**: Continue operating even when some agents fail

## Configuration

The system is configured via `Config` type with:
- Core service address for gRPC reporting
- Agent configurations including checker endpoints
- Polling intervals and timeouts
- Circuit breaker thresholds

## Future Enhancements

- [ ] Full OTP supervision tree implementation
- [ ] Dynamic agent discovery and registration
- [ ] Metrics and observability integration
- [ ] Hot code reloading for zero-downtime updates
- [ ] Distributed polling across multiple nodes