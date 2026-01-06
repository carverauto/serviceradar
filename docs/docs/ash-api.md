---
sidebar_position: 10
title: Ash JSON:API
---

# Ash JSON:API Endpoints

ServiceRadar exposes [JSON:API](https://jsonapi.org/) compliant endpoints through AshJsonApi for programmatic access to resources.

## API Overview

All Ash-backed endpoints are mounted at `/api/v2`:

| Domain | Base Path | Resources |
|--------|-----------|-----------|
| Inventory | `/api/v2/devices` | Device |
| Infrastructure | `/api/v2/gateways`, `/api/v2/agents` | Gateway, Agent |
| Monitoring | `/api/v2/service-checks`, `/api/v2/alerts` | ServiceCheck, Alert |
| Edge | `/api/v2/onboarding-packages` | OnboardingPackage |

## Authentication

All API requests require authentication via:

1. **JWT Bearer Token** (from user session)
2. **API Key** (from ApiToken resource)

```bash
# Using JWT
curl -H "Authorization: Bearer <jwt>" \
     https://api.serviceradar.cloud/api/v2/devices

# Using API Key
curl -H "Authorization: Bearer srk_<api_key>" \
     https://api.serviceradar.cloud/api/v2/devices
```

## Device Endpoints

### List Devices

```http
GET /api/v2/devices
```

**Query Parameters:**
- `filter[hostname]` - Filter by hostname
- `filter[is_available]` - Filter by availability (true/false)
- `filter[type_id]` - Filter by OCSF device type
- `page[limit]` - Items per page (default: 50)
- `page[offset]` - Pagination offset

**Response:**
```json
{
  "data": [
    {
      "type": "device",
      "id": "uuid",
      "attributes": {
        "uid": "device-001",
        "hostname": "server1.local",
        "is_available": true,
        "type_id": 1,
        "first_seen_time": "2024-01-15T10:00:00Z",
        "last_seen_time": "2024-01-15T12:00:00Z"
      },
      "relationships": {
        "group": { "data": null },
        "interfaces": { "data": [] }
      }
    }
  ],
  "meta": {
    "page": { "limit": 50, "offset": 0, "total": 1 }
  }
}
```

### Get Device

```http
GET /api/v2/devices/:id
```

### Create Device

```http
POST /api/v2/devices
Content-Type: application/vnd.api+json

{
  "data": {
    "type": "device",
    "attributes": {
      "uid": "new-device",
      "hostname": "new.local",
      "type_id": 1
    }
  }
}
```

### Update Device

```http
PATCH /api/v2/devices/:id
Content-Type: application/vnd.api+json

{
  "data": {
    "type": "device",
    "id": "uuid",
    "attributes": {
      "hostname": "updated.local"
    }
  }
}
```

## Alert Endpoints

### List Alerts

```http
GET /api/v2/alerts
```

**Query Parameters:**
- `filter[status]` - Filter by status (pending/acknowledged/resolved/escalated)
- `filter[severity]` - Filter by severity (info/warning/critical/emergency)

### Acknowledge Alert

```http
POST /api/v2/alerts/:id/acknowledge
Content-Type: application/vnd.api+json

{
  "data": {
    "type": "alert",
    "attributes": {
      "note": "Looking into this issue"
    }
  }
}
```

### Resolve Alert

```http
POST /api/v2/alerts/:id/resolve
Content-Type: application/vnd.api+json

{
  "data": {
    "type": "alert",
    "attributes": {
      "resolution_note": "Fixed by restarting service"
    }
  }
}
```

## Service Check Endpoints

### List Service Checks

```http
GET /api/v2/service-checks
```

**Available Filters:**
- `filter[enabled]` - Filter by enabled status
- `filter[check_type]` - Filter by type (ping/http/tcp/snmp/grpc/dns)
- `filter[agent_uid]` - Filter by assigned agent

### List Failing Checks

```http
GET /api/v2/service-checks/failing
```

Returns checks with `consecutive_failures > 0`.

## Gateway Endpoints

### List Gateways

```http
GET /api/v2/gateways
```

### Register Gateway

```http
POST /api/v2/gateways
Content-Type: application/vnd.api+json

{
  "data": {
    "type": "gateway",
    "attributes": {
      "id": "gateway-east-1",
      "component_id": "component-001",
      "registration_source": "kubernetes"
    }
  }
}
```

### Send Heartbeat

```http
POST /api/v2/gateways/:id/heartbeat
```

## Agent Endpoints

### List Agents

```http
GET /api/v2/agents
```

### Get Agents by Gateway

```http
GET /api/v2/agents?filter[gateway_id]=gateway-east-1
```

## Error Responses

All errors follow JSON:API error format:

```json
{
  "errors": [
    {
      "status": "403",
      "code": "forbidden",
      "title": "Forbidden",
      "detail": "You do not have permission to perform this action"
    }
  ]
}
```

**Common Error Codes:**
- `400` - Bad Request (validation errors)
- `401` - Unauthorized (missing/invalid auth)
- `403` - Forbidden (policy violation)
- `404` - Not Found
- `422` - Unprocessable Entity (changeset errors)

## SRQL Integration

For complex queries, use the SRQL endpoint which routes to Ash resources:

```http
POST /api/query
Content-Type: application/json

{
  "entity": "devices",
  "filters": {
    "is_available": true,
    "hostname": {"$like": "%.local"}
  },
  "sort": ["-last_seen_time"],
  "limit": 100
}
```

The SRQL adapter translates entity names:
- `devices` → `ServiceRadar.Inventory.Device`
- `gateways` → `ServiceRadar.Infrastructure.Gateway`
- `agents` → `ServiceRadar.Infrastructure.Agent`
- `alerts` → `ServiceRadar.Monitoring.Alert`

## Rate Limiting

API endpoints are rate-limited:
- **Standard**: 1000 requests/minute
- **Bulk operations**: 100 requests/minute
- **Authentication**: 10 attempts/minute

## Pagination

All list endpoints support keyset pagination:

```http
GET /api/v2/devices?page[limit]=25&page[after]=<cursor>
```

Response includes pagination metadata:
```json
{
  "links": {
    "first": "/api/v2/devices?page[limit]=25",
    "next": "/api/v2/devices?page[limit]=25&page[after]=xyz",
    "prev": null
  }
}
```
