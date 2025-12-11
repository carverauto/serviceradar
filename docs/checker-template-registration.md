# Checker Template Registration Design

**Status**: Implemented (Seeding + API)
**Created**: 2025-11-01
**Updated**: 2025-12-11
**Author**: AI Assistant with Matt Freeman

## Overview

This document describes the zero-touch checker configuration system that enables automated, scalable edge onboarding without manual configuration management.

### Goals

1. **Zero-Touch Onboarding**: Default checker templates are pre-seeded into KV
2. **KV-First Architecture**: All configurations stored and managed in NATS KV
3. **Template Discovery**: API endpoint lists available templates for UI dropdowns
4. **User Modifications Protected**: Instance configs are never overwritten once created
5. **Template Updates Safe**: Templates can be updated without affecting deployments

## Architecture

### Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Template Seeding (Bootstrap)                      │
│                                                                       │
│  Docker Compose: checker-templates-seed service seeds on startup     │
│  Helm: checker-templates-kv-bootstrap Job runs as post-install hook  │
│  Templates written to: templates/checkers/{kind}.json                │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│                     Edge Onboarding Process                          │
│                                                                       │
│  1. Admin creates edge package via Web UI or API                     │
│  2. Web UI fetches available templates via GET /api/admin/checker-   │
│     templates and displays them in a dropdown                        │
│  3. If checker_config_json not provided:                             │
│     - Fetch templates/checkers/{kind}.json from KV                   │
│     - Apply variable substitution (SPIFFE IDs, addresses, etc.)      │
│  4. Check if agents/{agent_id}/checkers/{kind}.json exists           │
│  5. If NOT exists: Write customized config                           │
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
      ├── sysmon.json        # Template for Linux sysmon checker (seeded)
      ├── sysmon-osx.json    # Template for macOS sysmon checker (seeded)
      ├── rperf.json         # Template for rperf network checker (seeded)
      ├── snmp.json          # Template for SNMP checker (seeded)
      └── dusk.json          # Template for Dusk browser checker (seeded)

agents/
  └── {agent-id}/
      └── checkers/
          ├── sysmon.json    # Instance config (written by edge onboarding)
          ├── snmp.json      # Instance config (never overwritten)
          └── rperf.json     # Instance config (user can modify via web UI)
```

### Write Rules

| Path Pattern | Written By | Overwrite Allowed | Purpose |
|-------------|------------|-------------------|---------|
| `templates/checkers/{kind}.json` | Seed job on deploy | ✅ Yes | Factory defaults, safe to update |
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

## Template Seeding Implementation

Templates are seeded into KV at deployment time rather than being self-registered by checkers. This simplifies checker code and ensures templates are available before any edge onboarding occurs.

### Template Source Files

Default templates are stored in the codebase at:
- `packaging/{checker}/config/checkers/{kind}.json` - Source templates for each checker

These templates are then:
1. Copied into `docker/compose/checker-templates/` for docker-compose deployments
2. Embedded in a Helm ConfigMap for Kubernetes deployments

### Docker Compose Seeding

The `docker-compose.yml` includes a `checker-templates-seed` service:

```yaml
checker-templates-seed:
  image: ghcr.io/carverauto/serviceradar-tools:${APP_TAG}
  volumes:
    - ./checker-templates:/templates:ro
    - cert-data:/etc/serviceradar/certs:ro
  command: ["sh", "/scripts/seed-checker-templates.sh"]
  depends_on:
    - nats
```

### Helm Chart Seeding

The Helm chart uses a Kubernetes Job as a post-install hook:

```yaml
# templates/checker-templates-kv-bootstrap-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "10"
spec:
  template:
    spec:
      containers:
        - name: kv-bootstrap
          image: ghcr.io/carverauto/serviceradar-tools:{{ .Values.image.tags.tools }}
          volumeMounts:
            - name: checker-templates
              mountPath: /etc/serviceradar/checker-templates
      volumes:
        - name: checker-templates
          configMap:
            name: serviceradar-checker-templates
```

Enable template seeding in values.yaml:
```yaml
checkerTemplates:
  enabled: true
```

### Adding a New Template

1. Create the template file in `packaging/{checker}/config/checkers/{kind}.json`
2. Copy to `docker/compose/checker-templates/{kind}.json`
3. Add to Helm ConfigMap in `templates/checker-templates-config.yaml`
4. Deploy - the seeding job will automatically upload the new template

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

### Template Discovery API

The `GET /api/admin/checker-templates` endpoint returns all available checker templates:

```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://demo.serviceradar.cloud/api/admin/checker-templates
```

**Response:**
```json
[
  {"kind": "sysmon", "template_key": "templates/checkers/sysmon.json"},
  {"kind": "sysmon-osx", "template_key": "templates/checkers/sysmon-osx.json"},
  {"kind": "snmp", "template_key": "templates/checkers/snmp.json"},
  {"kind": "rperf", "template_key": "templates/checkers/rperf.json"},
  {"kind": "dusk", "template_key": "templates/checkers/dusk.json"}
]
```

The web UI uses this endpoint to populate a dropdown selector for checker types, improving UX by eliminating the need for users to know template names.

## Migration Path

### Phase 1: Core Infrastructure (✅ Complete)
- [x] Implement template fetching in edge onboarding
- [x] Add variable substitution
- [x] Add overwrite protection
- [x] Deploy to k8s demo namespace

### Phase 2: Template Seeding (✅ Complete)
- [x] Create default templates for all checker types
- [x] Add docker-compose seed service (`checker-templates-seed`)
- [x] Add Helm chart KV bootstrap job (`checker-templates-kv-bootstrap`)
- [x] Add `ListCheckerTemplates` API endpoint for template discovery
- [x] Update web UI to show template dropdown

### Phase 3: Testing & Validation
- [ ] Test template seeding on docker-compose startup
- [ ] Test template seeding with Helm chart deployment
- [ ] Test edge onboarding without checker_config_json
- [ ] Test variable substitution for all supported variables
- [ ] Verify overwrite protection with web UI modifications

### Phase 4: Documentation & Tooling (Optional)
- [ ] Add admin API endpoints for template CRUD
- [ ] Create template validation tool
- [ ] Document template best practices
- [ ] Create migration guide for existing deployments

## Testing Checklist

### Template Seeding Testing

```bash
# Docker Compose: Verify seed service ran
docker compose logs checker-templates-seed | grep "Seeding checker template"

# Helm: Verify bootstrap job completed
kubectl get jobs -n demo | grep checker-templates-kv-bootstrap
kubectl logs -n demo -l app=serviceradar-checker-templates-kv-bootstrap

# Verify templates via API
curl -H "Authorization: Bearer $TOKEN" \
  https://demo.serviceradar.cloud/api/admin/checker-templates
# Expected: [{"kind":"sysmon","template_key":"templates/checkers/sysmon.json"}, ...]
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
1. Verify template seeding job completed successfully
   - Docker Compose: `docker compose logs checker-templates-seed`
   - Helm: `kubectl logs -n demo -l app=serviceradar-checker-templates-kv-bootstrap`
2. Check that `checkerTemplates.enabled: true` in Helm values
3. Verify template exists via API: `GET /api/admin/checker-templates`
4. Manually provide `checker_config_json` in edge package request as workaround

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
4. **Admin API**: REST endpoints for template CRUD (create, update, delete)
5. ~~**Template Discovery**: List available checker types and their templates~~ ✅ Implemented via `GET /api/admin/checker-templates`
6. **Dry-Run Mode**: Preview substituted config before writing

## References

- Edge Onboarding Implementation: `pkg/core/edge_onboarding.go`
- KV Service Proto: `proto/kv.proto`
- Template Discovery API: `pkg/core/api/edge_onboarding.go`
- Example Templates: `packaging/*/config/checkers/*.json`
- Docker Compose Templates: `docker/compose/checker-templates/`
- Helm Chart Templates: `helm/serviceradar/templates/checker-templates-config.yaml`
