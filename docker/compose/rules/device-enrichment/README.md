# Device Enrichment Override Rules

Place override YAML files here for local Docker Compose testing.

- Mounted into `core-elx` at `/var/lib/serviceradar/rules/device-enrichment`
- Rule IDs override built-in defaults when IDs match
- Restart `core-elx` after changing files

Example file: `my-overrides.yaml`

```yaml
rules:
  - id: ubiquiti-router-udm
    enabled: true
    priority: 1100
    confidence: 99
    reason: "Local override"
    match:
      all:
        ip_forwarding: [1]
      any:
        sys_descr: ["udm"]
    set:
      vendor_name: "Ubiquiti"
      type: "Router"
      type_id: 12
```
