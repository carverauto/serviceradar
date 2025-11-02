# Checker Template Registration Design

**Status**: Implemented (Core Service), In Progress (Checker Integration)
**Created**: 2025-11-01
**Author**: AI Assistant with Matt Freeman

## Overview

This document describes the zero-touch checker configuration system that enables automated, scalable edge onboarding without manual configuration management.

### Goals

1. **Zero-Touch Onboarding**: Checkers self-register their default configurations
2. **KV-First Architecture**: All configurations stored and managed in NATS KV
3. **No Additional Tools**: No need for external CLI tools or manual uploads
4. **User Modifications Protected**: Instance configs are never overwritten once created
5. **Template Updates Safe**: Checkers can update default templates without affecting deployments

## Architecture

### Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Checker Startup                               │
│                                                                       │
│  1. Checker loads default config from embedded/shipped file          │
│  2. Checker writes to templates/checkers/{kind}.json in KV           │
│     (Safe to overwrite - this is the "factory default")              │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│                     Edge Onboarding Process                          │
│                                                                       │
│  1. Admin creates edge package via API                               │
│  2. If checker_config_json not provided:                             │
│     - Fetch templates/checkers/{kind}.json from KV                   │
│     - Apply variable substitution (SPIFFE IDs, addresses, etc.)      │
│  3. Check if agents/{agent_id}/checkers/{kind}.json exists           │
│  4. If NOT exists: Write customized config                           │
│     If EXISTS: Skip write (preserve user modifications)              │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│                      Runtime Configuration                           │
│                                                                       │
│  Agent reads: agents/{agent_id}/checkers/{kind}.json                 │
│  Web UI edits: agents/{agent_id}/checkers/{kind}.json                │
│  Updates are preserved (never overwritten by onboarding)             │
└─────────────────────────────────────────────────────────────────────┘
```

### KV Key Structure

```
templates/
  └── checkers/
      ├── sysmon.json        # Template for sysmon checker (written by checker)
      ├── sweep.json         # Template for sweep checker (written by checker)
      ├── rperf.json         # Template for rperf checker (written by checker)
      └── snmp.json          # Template for snmp checker (written by checker)

agents/
  └── {agent-id}/
      └── checkers/
          ├── sysmon.json    # Instance config (written by edge onboarding)
          ├── sweep.json     # Instance config (never overwritten)
          └── rperf.json     # Instance config (user can modify via web UI)
```

### Write Rules

| Path Pattern | Written By | Overwrite Allowed | Purpose |
|-------------|------------|-------------------|---------|
| `templates/checkers/{kind}.json` | Checker on startup | ✅ Yes | Factory defaults, safe to update |
| `agents/{agent_id}/checkers/{kind}.json` | Edge onboarding | ❌ No | Instance config, user modifications protected |
| `agents/{agent_id}/checkers/{kind}.json` | Web UI | ✅ Yes | User modifications |

## Template Format

### Variable Substitution

Templates can include placeholders that are automatically substituted during edge onboarding:

**Available Variables:**

- `{{DOWNSTREAM_SPIFFE_ID}}` - The checker's SPIFFE ID
- `{{AGENT_ADDRESS}}` - Address of the parent agent
- `{{CORE_ADDRESS}}` - Address of the core service
- `{{CORE_SPIFFE_ID}}` - SPIFFE ID of the core service
- `{{KV_ADDRESS}}` - Address of the KV service
- `{{KV_SPIFFE_ID}}` - SPIFFE ID of the KV service
- `{{TRUST_DOMAIN}}` - SPIFFE trust domain
- `{{LOG_LEVEL}}` - Configured log level
- `{{COMPONENT_ID}}` - Unique component identifier
- `{{CHECKER_KIND}}` - Type of checker (sysmon, sweep, etc.)
- `{{AGENT_ID}}` - Parent agent ID

**Both formats supported:**
- `{{VARIABLE}}` (recommended)
- `${VARIABLE}` (alternate)

### Example Template

```json
{
  "listen_addr": "0.0.0.0:50083",
  "security": {
    "mode": "spiffe",
    "cert_dir": "/etc/serviceradar/certs",
    "trust_domain": "{{TRUST_DOMAIN}}",
    "workload_socket": "unix:/run/spire/sockets/agent.sock",
    "server_spiffe_id": "{{DOWNSTREAM_SPIFFE_ID}}"
  },
  "poll_interval": 30,
  "log_level": "{{LOG_LEVEL}}",
  "core_address": "{{CORE_ADDRESS}}",
  "filesystems": [
    {
      "name": "/",
      "type": "ext4",
      "monitor": true
    }
  ]
}
```

## Implementation Guide

### Requirements for All Checkers

1. **Load Default Config**: Read from embedded/shipped config file
2. **Connect to KV**: Use KV address from metadata or environment
3. **Write Template**: Write to `templates/checkers/{kind}.json`
4. **Handle Errors Gracefully**: Template write failures should not prevent startup
5. **Log Activity**: Log template registration for debugging

### Go Implementation Example

```go
package main

import (
    "context"
    "encoding/json"
    "os"

    "github.com/carverauto/serviceradar/pkg/config"
    "github.com/carverauto/serviceradar/proto"
)

func registerTemplate(ctx context.Context, kvClient proto.KVServiceClient, checkerKind string) error {
    // Load default config from shipped file
    defaultConfigPath := "/usr/share/serviceradar/checkers/" + checkerKind + "/default.json"
    configData, err := os.ReadFile(defaultConfigPath)
    if err != nil {
        return fmt.Errorf("failed to read default config: %w", err)
    }

    // Validate it's valid JSON
    if !json.Valid(configData) {
        return fmt.Errorf("default config is not valid JSON")
    }

    // Write to KV template location
    templateKey := fmt.Sprintf("templates/checkers/%s.json", checkerKind)

    _, err = kvClient.Put(ctx, &proto.PutRequest{
        Key:   templateKey,
        Value: configData,
    })
    if err != nil {
        return fmt.Errorf("failed to write template to KV: %w", err)
    }

    log.Info().
        Str("template_key", templateKey).
        Str("checker_kind", checkerKind).
        Msg("Successfully registered checker template")

    return nil
}

func main() {
    ctx := context.Background()

    // Initialize KV client from environment
    kvClient, closer, err := config.NewKVServiceClientFromEnv(ctx, models.RoleChecker)
    if err != nil {
        log.Warn().Err(err).Msg("Failed to initialize KV client, skipping template registration")
    } else {
        defer closer()

        // Register template (non-fatal if it fails)
        if err := registerTemplate(ctx, kvClient, "sysmon"); err != nil {
            log.Warn().Err(err).Msg("Failed to register template, continuing startup")
        }
    }

    // Continue with normal checker startup...
}
```

### Rust Implementation Example

```rust
use tonic::Request;
use prost::Message;

async fn register_template(
    kv_client: &mut KvServiceClient<Channel>,
    checker_kind: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Load default config from embedded resource or file
    let default_config_path = format!(
        "/usr/share/serviceradar/checkers/{}/default.json",
        checker_kind
    );
    let config_data = tokio::fs::read(&default_config_path).await?;

    // Validate JSON
    serde_json::from_slice::<serde_json::Value>(&config_data)?;

    // Write to KV template location
    let template_key = format!("templates/checkers/{}.json", checker_kind);

    let request = Request::new(PutRequest {
        key: template_key.clone(),
        value: config_data,
        ttl_seconds: 0,
    });

    kv_client.put(request).await?;

    tracing::info!(
        template_key = %template_key,
        checker_kind = %checker_kind,
        "Successfully registered checker template"
    );

    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize KV client from environment
    let kv_address = std::env::var("KV_ADDRESS")
        .unwrap_or_else(|_| "serviceradar-datasvc:50057".to_string());

    match connect_to_kv(&kv_address).await {
        Ok(mut kv_client) => {
            // Register template (non-fatal if it fails)
            if let Err(e) = register_template(&mut kv_client, "sysmon").await {
                tracing::warn!(error = %e, "Failed to register template, continuing startup");
            }
        }
        Err(e) => {
            tracing::warn!(error = %e, "Failed to connect to KV, skipping template registration");
        }
    }

    // Continue with normal checker startup...
    Ok(())
}
```

## Configuration Sources

### Default Config Location by Language

**Go Checkers:**
```
/usr/share/serviceradar/checkers/{kind}/default.json
```

**Rust Checkers:**
```
/usr/share/serviceradar/checkers/{kind}/default.json
```

Or embedded in binary:
```rust
const DEFAULT_CONFIG: &str = include_str!("../config/default.json");
```

## Edge Onboarding Integration

### Core Service Implementation

The core service has been updated with the following changes in `/home/mfreeman/serviceradar/pkg/core/edge_onboarding.go`:

1. **Template Fetching** (Line ~1495-1517):
   - Checks if `checker_config_json` is provided
   - If not, fetches from `templates/checkers/{checker_kind}.json`
   - Returns error if template not found and no config provided

2. **Variable Substitution** (Line ~1674-1743):
   - `substituteTemplateVariables()`: Parses JSON and applies substitutions
   - `substituteInMap()`: Recursively processes nested structures
   - Supports both `{{VAR}}` and `${VAR}` formats

3. **Overwrite Protection** (Line ~1475-1491):
   - Checks if instance config already exists
   - Skips write if found (preserves user modifications)
   - Logs the skip for auditing

### API Usage

**Without Config (Uses Template):**
```bash
curl -X POST https://demo.serviceradar.cloud/api/admin/edge-packages \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "label": "Sysmon Checker - Site A",
    "component_type": "checker",
    "checker_kind": "sysmon",
    "parent_id": "agent-site-a",
    "downstream_spiffe_id": "spiffe://example.com/site-a/sysmon",
    "metadata_json": "{...}"
  }'
```

**With Custom Config (Skips Template):**
```bash
curl -X POST https://demo.serviceradar.cloud/api/admin/edge-packages \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "label": "Custom Sysmon",
    "component_type": "checker",
    "checker_kind": "sysmon",
    "parent_id": "agent-site-a",
    "checker_config_json": "{\"custom\": \"config\"}",
    "metadata_json": "{...}"
  }'
```

## Migration Path

### Phase 1: Core Infrastructure (✅ Complete)
- [x] Implement template fetching in edge onboarding
- [x] Add variable substitution
- [x] Add overwrite protection
- [x] Deploy to k8s demo namespace

### Phase 2: Checker Integration (📋 In Progress)
- [ ] Add template registration to sysmon checker (Rust)
- [ ] Add template registration to sweep checker (Go)
- [ ] Add template registration to rperf checker (Go)
- [ ] Add template registration to snmp checker (Go)
- [ ] Add template registration to dusk checker (Go)

### Phase 3: Testing & Validation
- [ ] Test template registration on first checker startup
- [ ] Test template updates on checker restart
- [ ] Test edge onboarding without checker_config_json
- [ ] Test variable substitution for all supported variables
- [ ] Verify overwrite protection with web UI modifications

### Phase 4: Documentation & Tooling (Optional)
- [ ] Add admin API endpoints for template CRUD
- [ ] Create template validation tool
- [ ] Document template best practices
- [ ] Create migration guide for existing deployments

## Testing Checklist

### Template Registration Testing

```bash
# 1. Deploy checker for first time
kubectl logs -n demo checker-pod | grep "registered checker template"

# 2. Verify template in KV
# (Would need KV client tool or debug endpoint)

# 3. Restart checker, verify template updated
kubectl delete pod checker-pod
kubectl logs -n demo checker-pod | grep "registered checker template"
```

### Edge Onboarding Testing

```bash
# 1. Create package without checker_config_json
curl -X POST .../edge-packages -d '{"checker_kind": "sysmon", ...}'

# 2. Verify config was written
# Check logs for "Using checker template from KV"

# 3. Verify variables were substituted
# Inspect agents/{agent_id}/checkers/sysmon.json in KV

# 4. Try to create another package for same agent+kind
curl -X POST .../edge-packages -d '{"checker_kind": "sysmon", ...}'

# 5. Verify existing config was NOT overwritten
# Check logs for "Checker config already exists in KV, skipping write"
```

### Overwrite Protection Testing

```bash
# 1. Modify config via web UI
# Edit agents/{agent_id}/checkers/sysmon.json

# 2. Create new edge package for same checker
curl -X POST .../edge-packages ...

# 3. Verify user modifications preserved
# Check that config still has user's changes
```

## Security Considerations

1. **SPIFFE Authentication**: Checkers must have SPIFFE credentials to write to KV
2. **Template Validation**: Templates should be validated before writing
3. **Rate Limiting**: Consider rate limiting template writes to prevent abuse
4. **Audit Logging**: All template writes should be logged
5. **Access Control**: Only checkers should write templates, only core/web-ui should write instance configs

## Troubleshooting

### Template Not Found Error

**Symptom**: Edge onboarding fails with "no template found at templates/checkers/{kind}.json"

**Solution**:
1. Verify checker has started and registered its template
2. Check checker logs for template registration
3. Manually provide `checker_config_json` in edge package request
4. Or manually upload template to KV

### Variables Not Substituted

**Symptom**: Config contains literal `{{VARIABLE}}` values

**Solution**:
1. Verify metadata_json contains required fields
2. Check core logs for substitution warnings
3. Ensure variables use correct format: `{{VAR}}` or `${VAR}`

### Config Overwritten

**Symptom**: User modifications lost after edge onboarding

**Solution**:
1. This should not happen - check core logs
2. Verify overwrite protection logic is working
3. File bug report with logs

## Future Enhancements

1. **Template Versioning**: Track template versions and migrations
2. **Template Validation**: JSON schema validation for templates
3. **Template Inheritance**: Base templates with overrides
4. **Admin API**: REST endpoints for template management
5. **Template Discovery**: List available checker types and their templates
6. **Dry-Run Mode**: Preview substituted config before writing

## References

- Edge Onboarding Implementation: `/home/mfreeman/serviceradar/pkg/core/edge_onboarding.go`
- KV Service Proto: `/home/mfreeman/serviceradar/proto/kv.proto`
- Config Utility: `/home/mfreeman/serviceradar/pkg/config/kv_client.go`
- Example Templates: `/home/mfreeman/serviceradar/packaging/*/config/checkers/*.json`
