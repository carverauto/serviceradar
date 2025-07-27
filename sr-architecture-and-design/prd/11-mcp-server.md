# ServiceRadar SRQL Integration with GoMCP

| Metadata | Value                             |
|----------|-----------------------------------|
| Date     | 2025-07-27                        |
| Author   | @mfreeman                         |
| Status   | `Proposed`                        |
| Tags     | serviceradar, server, mcp, srql   |

| Revision | Date       | Author    | Info           |
|----------|------------|-----------|----------------|
| 1        | 2025-07-27 | @mfreeman | Initial design |

## Context and Problem Statement

ServiceRadar currently provides powerful data acquisition and storage capabilities for network monitoring, but access to this data is primarily through direct database access or predefined API endpoints. How can we enhance data accessibility and enable modern, conversational interfaces for users and Large Language Models (LLMs) to interact with our data more dynamically? The ServiceRadar Query Language (SRQL) offers flexible syntax for querying our datasets, but it is not directly accessible through a user-friendly, standardized API suitable for LLM integration.

## Context

### Current State
- ServiceRadar provides network monitoring with data acquisition and storage
- Access is limited to direct database queries or predefined API endpoints
- SRQL exists but requires expertise to use effectively
- LLMs struggle to learn SRQL nuances without a proper interface

### Go Model Context Protocol (GoMCP)
- GoMCP is a library that enables exposing services through the Model Context Protocol
- Provides a standardized way for LLMs to interact with external systems
- Supports tool-based interfaces that are discoverable and self-documenting

### User Personas
- **Network Administrator / SRE:** Uses LLM-powered chat interfaces to query network data
- **Developer / Integrator:** Builds custom applications using well-defined MCP toolsets

## Design

### Architecture Overview
Integration of GoMCP library with ServiceRadar platform to expose granular, intent-based tools over a secure MCP server. These tools internally construct and execute SRQL queries while providing a simple, discoverable interface for LLMs.

### MCP Server Component
- New MCP server component within ServiceRadar application
- Lifecycle managed by main `core.Server` (startup/shutdown)
- Configurable via `CoreServiceConfig` (enable/disable, listening address)
- HTTP or WebSocket transport using `gomcp`

### Granular MCP Tools

#### Device Management Tools
- **`devices.getDevices`**: Retrieves device list with filtering, sorting, and pagination
    - Inputs: filter (SRQL WHERE clause), limit, orderBy, sortDesc
- **`devices.getDevice`**: Retrieves single device by ID
    - Inputs: deviceID (required)

#### Log Management Tools
- **`logs.getLogs`**: Searches log entries
    - Inputs: filter, startTime, endTime, limit

#### Event Management Tools
- **`events.getEvents`**: Searches system/network events
    - Inputs: filter, startTime, endTime, limit

#### Network Sweep Tools
- **`sweeps.getResults`**: Retrieves network sweep results
    - Inputs: filter, limit

#### Power User Tool
- **`srql.query`**: Direct SRQL execution for advanced users
    - Inputs: query (raw SRQL string)

### Security Architecture
- HTTP endpoint protected by ServiceRadar's existing authentication middleware
- JWT token required for MCP endpoint access
- `gomcp.server.Context` provides session information for scoped data access

### Technical Implementation

#### Package Structure
```
pkg/mcp/
├── server.go          # MCPServer struct and lifecycle
├── tools_devices.go   # Device tool handlers
├── tools_logs.go      # Log tool handlers
├── tools_events.go    # Event tool handlers
├── tools_srql.go      # Power-user tool handler
└── builder.go         # SRQL query construction helper
```

#### SRQL Query Builder
Dynamic query construction from tool arguments:
```go
func BuildSRQL(entity, filter, orderBy string, limit int, sortDesc bool) string
```

#### Handler Pattern
Each tool handler follows a consistent pattern:
1. Receive structured arguments
2. Build SRQL query using builder
3. Parse query with SRQL parser
4. Translate to SQL
5. Execute against database
6. Return results

## Decision

### Primary Goal
Expose ServiceRadar's data via a secure, LLM-friendly set of MCP tools.

### Key Decisions
1. **Tool Granularity**: Create specific tools for each entity type rather than a single generic query tool
2. **SRQL Abstraction**: Hide SRQL complexity behind simple parameter interfaces
3. **Security Integration**: Leverage existing authentication rather than building new security layer
4. **Power User Support**: Include direct SRQL access for advanced use cases
5. **Lifecycle Management**: Integrate MCP server lifecycle with core service

### Objectives
- Create entity-specific MCP tools (getLogs, getDevices, etc.)
- Abstract SRQL complexity from clients
- Ensure secure integration with existing authentication
- Provide power-user tool for direct SRQL execution
- Establish foundation for advanced LLM features
- Manage MCP server lifecycle within core service

## Consequences

### Success Metrics
- **Functionality**: LLM agents can successfully query devices, logs, and events
- **Discoverability**: Developers can integrate without deep SRQL knowledge
- **Security**: Unauthorized requests are properly rejected
- **Stability**: Graceful handling of invalid inputs
- **Performance**: Query response times < 2 seconds for common operations

### Future Enhancements
- **MCP Resources**: Expose individual entities as resources (e.g., `/devices/{deviceID}`)
- **MCP Prompts**: Predefined prompts for complex multi-step reports
- **Natural Language Filters**: LLM-provided natural language filters translated to SRQL WHERE clauses
- **Advanced Reporting**: Complex analytical queries and aggregations
- **Real-time Subscriptions**: Push-based updates for monitoring use cases

### Breaking Changes
- None - this is an additive feature that doesn't modify existing APIs

### Dependencies
- Requires GoMCP library integration
- Depends on existing SRQL parser and translator
- Leverages current authentication infrastructure