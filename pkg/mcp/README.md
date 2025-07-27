# ServiceRadar MCP Server

This package implements a Model Context Protocol (MCP) server for ServiceRadar, enabling LLMs and AI agents to interact with ServiceRadar data through a standardized interface.

## Overview

The ServiceRadar MCP server exposes ServiceRadar's data through a set of granular, intent-based tools that internally construct and execute SRQL (ServiceRadar Query Language) queries. This provides a simple, discoverable interface for LLMs while hiding the complexity of SRQL from clients.

## Features

### Entity-Specific Tools

- **Device Management**: `devices.getDevices`, `devices.getDevice`
- **Log Management**: `logs.getLogs`, `logs.getRecentLogs`
- **Event Management**: `events.getEvents`, `events.getAlerts`, `events.getEventTypes`
- **Network Sweeps**: `sweeps.getResults`, `sweeps.getRecentSweeps`, `sweeps.getSweepSummary`
- **Direct SRQL**: `srql.query`, `srql.validate`, `srql.schema`, `srql.examples`

### Key Benefits

- **LLM-Friendly**: Tools are designed for easy discovery and use by AI agents
- **SRQL Abstraction**: Hides SRQL complexity behind simple parameter interfaces
- **Type Safety**: Strong typing for all tool parameters and responses
- **Authentication**: Integrated with ServiceRadar's existing authentication system
- **Comprehensive**: Covers all major ServiceRadar data entities

## Configuration

Add the MCP configuration to your ServiceRadar core configuration:

```json
{
  "mcp": {
    "enabled": true,
    "host": "localhost",
    "port": "8081"
  }
}
```

### Configuration Options

- `enabled` (bool): Enable/disable the MCP server
- `host` (string): Host to bind the MCP server (default: "localhost")
- `port` (string): Port for the MCP server (default: "8081")

## Authentication

The MCP server integrates with ServiceRadar's authentication system. Clients must provide authentication via:

1. **Environment Variable**: Set `AUTHORIZATION` with value `Bearer <token>`
2. **Direct Token**: Set `AUTH_TOKEN` with the token value

Example client authentication:
```bash
export AUTHORIZATION="Bearer your-jwt-token-here"
# or
export AUTH_TOKEN="your-jwt-token-here"
```

## Usage Examples

### Basic Device Query
```json
{
  "method": "tools/call",
  "params": {
    "name": "devices.getDevices",
    "arguments": {
      "limit": 10,
      "order_by": "timestamp",
      "sort_desc": true
    }
  }
}
```

### Device Filtering
```json
{
  "method": "tools/call",
  "params": {
    "name": "devices.getDevices", 
    "arguments": {
      "filter": "poller_id = 'poller-001'",
      "limit": 50
    }
  }
}
```

### Log Search with Time Range
```json
{
  "method": "tools/call",
  "params": {
    "name": "logs.getLogs",
    "arguments": {
      "filter": "level = 'error'",
      "start_time": "2025-01-01T00:00:00Z",
      "end_time": "2025-01-02T00:00:00Z",
      "limit": 100
    }
  }
}
```

### Direct SRQL Query
```json
{
  "method": "tools/call",
  "params": {
    "name": "srql.query",
    "arguments": {
      "query": "SELECT * FROM devices WHERE available = true ORDER BY timestamp DESC LIMIT 20"
    }
  }
}
```

## Available Tools

### Device Tools

#### `devices.getDevices`
Retrieves device list with filtering, sorting, and pagination.

**Parameters:**
- `filter` (string, optional): SRQL WHERE clause
- `limit` (int, optional): Maximum results
- `order_by` (string, optional): Field to sort by
- `sort_desc` (bool, optional): Sort descending

#### `devices.getDevice`
Retrieves single device by ID.

**Parameters:**
- `device_id` (string, required): Device identifier

### Log Tools

#### `logs.getLogs`
Searches log entries with optional time filtering.

**Parameters:**
- `filter` (string, optional): SRQL WHERE clause
- `start_time` (timestamp, optional): Start time filter
- `end_time` (timestamp, optional): End time filter
- `limit` (int, optional): Maximum results
- `order_by` (string, optional): Field to sort by
- `sort_desc` (bool, optional): Sort descending

#### `logs.getRecentLogs`
Get recent logs with simple limit.

**Parameters:**
- `limit` (int, optional): Maximum results (default 100)
- `poller_id` (string, optional): Optional poller filter

### Event Tools

#### `events.getEvents`
Searches system/network events with comprehensive filtering.

**Parameters:**
- `filter` (string, optional): SRQL WHERE clause
- `start_time` (timestamp, optional): Start time filter
- `end_time` (timestamp, optional): End time filter
- `limit` (int, optional): Maximum results
- `order_by` (string, optional): Field to sort by
- `sort_desc` (bool, optional): Sort descending
- `event_type` (string, optional): Filter by event type
- `severity` (string, optional): Filter by severity level

#### `events.getAlerts`
Get alert-level events (high severity events).

**Parameters:**
- `limit` (int, optional): Maximum results (default 50)
- `start_time` (timestamp, optional): Start time filter
- `poller_id` (string, optional): Optional poller filter

#### `events.getEventTypes`
Get available event types in the system.

**Parameters:** None

### Sweep Tools

#### `sweeps.getResults`
Retrieves network sweep results with comprehensive filtering.

**Parameters:**
- `filter` (string, optional): SRQL WHERE clause
- `start_time` (timestamp, optional): Start time filter
- `end_time` (timestamp, optional): End time filter
- `limit` (int, optional): Maximum results
- `order_by` (string, optional): Field to sort by
- `sort_desc` (bool, optional): Sort descending
- `poller_id` (string, optional): Filter by poller ID
- `network` (string, optional): Filter by network range

#### `sweeps.getRecentSweeps`
Get recent network sweeps with simple filtering.

**Parameters:**
- `limit` (int, optional): Maximum results (default 20)
- `poller_id` (string, optional): Optional poller filter
- `hours` (int, optional): Last N hours (default 24)

#### `sweeps.getSweepSummary`
Get summary statistics for network sweeps.

**Parameters:**
- `poller_id` (string, optional): Optional poller filter
- `start_time` (timestamp, optional): Start time filter
- `end_time` (timestamp, optional): End time filter

### SRQL Tools

#### `srql.query`
Execute raw SRQL queries for advanced users.

**Parameters:**
- `query` (string, required): Raw SRQL query string

#### `srql.validate`
Validate SRQL query syntax without execution.

**Parameters:**
- `query` (string, required): SRQL query to validate

#### `srql.schema`
Get available tables and schema information for SRQL queries.

**Parameters:**
- `entity` (string, optional): Specific entity to describe

#### `srql.examples`
Get example SRQL queries for learning and reference.

**Parameters:** None

## Integration with Claude Code

To use the ServiceRadar MCP server with Claude Code, create an MCP configuration file:

```json
{
  "mcpServers": {
    "serviceradar": {
      "command": "serviceradar-core",
      "args": ["--config", "/path/to/config.json"],
      "env": {
        "AUTHORIZATION": "${SERVICERADAR_TOKEN}"
      }
    }
  }
}
```

## Error Handling

The MCP server returns structured error responses:

```json
{
  "error": {
    "code": -32001,
    "message": "Authentication required: no token provided"
  }
}
```

Common error scenarios:
- Missing authentication
- Invalid SRQL syntax
- Database connection issues
- Invalid parameters

## Logging

The MCP server uses ServiceRadar's logging system. Log levels and destinations are configured through the main ServiceRadar configuration.

## Security

- All tools require authentication when auth service is configured
- SQL injection protection through parameterized queries
- Input validation on all parameters
- Secure token verification through ServiceRadar's auth system