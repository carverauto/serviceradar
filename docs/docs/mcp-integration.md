---
sidebar_position: 11
title: MCP Integration
---

# Model Context Protocol (MCP) Integration

ServiceRadar includes integrated support for the Model Context Protocol (MCP), which allows Large Language Models (LLMs) to interact with ServiceRadar's data through a standardized interface. This enables AI assistants to query, analyze, and understand your network monitoring data.

## What is MCP?

The Model Context Protocol (MCP) is an open standard for connecting AI assistants to data sources and tools. ServiceRadar's MCP server exposes ServiceRadar's monitoring data through a set of discoverable tools that LLMs can use to:

- Query device information and availability
- Search through log entries
- Analyze system events and alerts
- Review network sweep results
- Execute custom SRQL queries

## Features

- **Intent-based Tools**: High-level tools that hide SRQL complexity behind simple parameter interfaces
- **SRQL Access**: Direct access to ServiceRadar Query Language for power users
- **Real-time Data**: Live access to current monitoring data
- **Secure**: Uses existing ServiceRadar authentication
- **Integrated**: Runs within the same process as the API server for optimal performance

## Configuration

### Enable MCP Server

Add MCP configuration to your core service configuration file (e.g., `/etc/serviceradar/core.json`):

```json
{
  "listen_addr": "0.0.0.0:8080",
  "grpc_addr": "0.0.0.0:50051",
  "database": {
    "addr": "localhost:8123",
    "name": "serviceradar",
    "user": "default",
    "pass": ""
  },
  "mcp": {
    "enabled": true,
    "api_key": "your-secure-api-key-here"
  }
}
```

### Configuration Options

- **`enabled`**: Set to `true` to enable the MCP server
- **`api_key`**: API key for authentication (required when enabled)

### API Key Authentication

The MCP server uses the same authentication system as the ServiceRadar API. Generate a secure API key and ensure your MCP client includes it in requests:

```
Authorization: Bearer your-secure-api-key-here
```

## Available Tools

### Device Management Tools

#### `devices.getDevices`
Retrieves device list with filtering, sorting, and pagination.

**Parameters:**
- `filter` (optional): SRQL WHERE clause for filtering
- `limit` (optional): Maximum number of results
- `order_by` (optional): Field to sort by
- `sort_desc` (optional): Sort in descending order

**Example:**
```json
{
  "filter": "available = true",
  "limit": 50,
  "order_by": "last_seen",
  "sort_desc": true
}
```

#### `devices.getDevice`
Retrieves a single device by ID.

**Parameters:**
- `device_id` (required): Device identifier

### Log Management Tools

#### `logs.getLogs`
Searches log entries with optional time filtering.

**Parameters:**
- `filter` (optional): SRQL WHERE clause
- `start_time` (optional): Start time for filtering (ISO 8601)
- `end_time` (optional): End time for filtering (ISO 8601)
- `limit` (optional): Maximum number of results

#### `logs.getRecentLogs`
Get recent logs with simple filtering.

**Parameters:**
- `limit` (optional): Maximum results (default 100)
- `poller_id` (optional): Filter by poller ID

### Event Management Tools

#### `events.getEvents`
Searches system/network events with comprehensive filtering.

**Parameters:**
- `filter` (optional): SRQL WHERE clause
- `start_time` (optional): Start time for filtering
- `end_time` (optional): End time for filtering
- `event_type` (optional): Filter by event type
- `severity` (optional): Filter by severity level
- `limit` (optional): Maximum number of results

#### `events.getAlerts`
Get alert-level events (high severity events).

**Parameters:**
- `limit` (optional): Maximum results (default 50)
- `start_time` (optional): Start time filter
- `poller_id` (optional): Filter by poller ID

#### `events.getEventTypes`
Get available event types in the system.

### Network Sweep Tools

#### `sweeps.getResults`
Retrieves network sweep results with comprehensive filtering.

**Parameters:**
- `filter` (optional): SRQL WHERE clause
- `start_time` (optional): Start time for filtering
- `end_time` (optional): End time for filtering
- `poller_id` (optional): Filter by poller ID
- `network` (optional): Filter by network range
- `limit` (optional): Maximum number of results

#### `sweeps.getRecentSweeps`
Get recent network sweeps with simple filtering.

**Parameters:**
- `limit` (optional): Maximum results (default 20)
- `poller_id` (optional): Filter by poller ID
- `hours` (optional): Last N hours (default 24)

### SRQL Power User Tools

#### `srql.query`
Execute raw SRQL queries for advanced users.

**Parameters:**
- `query` (required): Raw SRQL query string

**Example:**
```json
{
  "query": "in:devices device.ip:192.168.1.% sort:last_seen:desc limit:10"
}
```

#### `srql.validate`
Validate SRQL query syntax without execution.

**Parameters:**
- `query` (required): SRQL query to validate

#### `srql.schema`
Get available tables and schema information.

**Parameters:**
- `entity` (optional): Specific entity to describe

#### `srql.examples`
Get example SRQL queries for learning and reference.

## API Endpoints

The MCP server exposes endpoints under `/api/mcp/`:

- **`POST /api/mcp/tools/call`**: Execute an MCP tool
- **`GET /api/mcp/tools/list`**: List available MCP tools

## Tool Execution Format

### Request Format

```json
{
  "method": "tool_call",
  "params": {
    "name": "devices.getDevices",
    "arguments": {
      "filter": "available = true",
      "limit": 10
    }
  }
}
```

### Response Format

```json
{
  "result": {
    "devices": [...],
    "count": 10,
    "query": "in:devices available:true limit:10"
  }
}
```

### Error Response

```json
{
  "error": {
    "code": 400,
    "message": "Invalid device filter arguments: filter syntax error"
  }
}
```

## SRQL Query Language Basics

ServiceRadar Query Language (SRQL) uses key:value selectors. Always start with `in:<entity>` to pick a dataset, then add filters, sorting, limits, and analytics directives.

### Listing Data
```text
in:devices limit:20 sort:last_seen:desc
in:logs severity_text:error time:last_1h sort:timestamp:desc
in:activity severity_id:critical
```

### Filtering
```text
in:devices available:false sort:last_seen:desc
in:activity connection.src_endpoint_ip:10.% connection.dst_endpoint_port:(22,2222)
in:logs !service_name:"serviceradar-web"
```

### Sorting and Limiting
```text
in:devices sort:last_seen:desc limit:50
in:logs severity_text:error sort:timestamp:desc limit:100
```

### Time Ranges
```text
in:activity time:[2025-01-01T00:00:00Z,2025-01-02T00:00:00Z]
in:logs time:last_24h
```

### Aggregations
```text
in:devices stats:"count() as total by poller_id" sort:total:desc
in:activity time:last_1h stats:"count() as events by severity_id" having:"events>100"
```

## Example Use Cases

### Check Device Availability
Query all unavailable devices:
```json
{
  "name": "devices.getDevices",
  "arguments": {
    "filter": "available = false",
    "order_by": "last_seen",
    "sort_desc": true
  }
}
```

### Recent Critical Events
Get critical events from the last hour:
```json
{
  "name": "events.getEvents",
  "arguments": {
    "severity": "critical",
    "start_time": "2025-01-27T10:00:00Z",
    "limit": 20
  }
}
```

### Network Sweep Analysis
Analyze recent network discoveries:
```json
{
  "name": "sweeps.getRecentSweeps",
  "arguments": {
    "hours": 6,
    "limit": 100
  }
}
```

### Custom SRQL Query
Execute complex analysis queries:
```json
{
  "name": "srql.query",
  "arguments": {
    "query": "in:devices device.ip:10.% available:false sort:last_seen:desc"
  }
}
```

## Security Considerations

- **API Key Protection**: Keep your API key secure and rotate it regularly
- **Network Security**: The MCP server runs on the same endpoints as the API server
- **Authentication**: All MCP requests require valid API key authentication
- **Rate Limiting**: Consider implementing rate limiting for MCP endpoints if needed

## Troubleshooting

### MCP Server Not Starting
1. Check that `mcp.enabled` is set to `true` in configuration
2. Verify that `mcp.api_key` is configured
3. Check ServiceRadar logs for MCP initialization messages

### Authentication Errors
1. Verify API key is correct and active
2. Check that Authorization header is properly formatted
3. Ensure API key has necessary permissions

### Tool Execution Errors
1. Validate SRQL syntax using `srql.validate` tool
2. Check parameter formatting in tool arguments
3. Review ServiceRadar logs for detailed error messages

### No Data Returned
1. Verify that filters are not too restrictive
2. Check that data exists in the specified time ranges
3. Use `srql.schema` to verify available fields and entities

## Integration Examples

The MCP server is designed to work with various AI assistants and applications that support the Model Context Protocol. Refer to your specific LLM client documentation for integration details.
