# Mapper Baseline CLI

`mapper-baseline` runs the existing Go mapper/discovery engine as a one-shot baseline without writing to CNPG.

Phase 1 supports:
- explicit SNMP targets plus credentials
- explicit UniFi controller URL plus API key
- explicit MikroTik controller URL plus username/password
- controller-only (`api`) and hybrid controller+SNMP (`snmp_api`) discovery modes
- stable JSON output for devices, interfaces, topology links, and summary counts

Examples:

```bash
bazel run //go/cmd/tools/mapper-baseline:mapper-baseline -- \
  --mode snmp \
  --seed 192.168.1.238 \
  --seed 192.168.1.138 \
  --snmp-version v2c \
  --snmp-community C4rv3rAut0 \
  --type topology \
  --output /tmp/farm-baseline.json
```

```bash
bazel run //go/cmd/tools/mapper-baseline:mapper-baseline -- \
  --mode unifi \
  --discovery-mode api \
  --unifi-base-url https://controller.example.com \
  --unifi-api-key "$UNIFI_API_KEY" \
  --type topology
```

```bash
bazel run //go/cmd/tools/mapper-baseline:mapper-baseline -- \
  --mode controller \
  --discovery-mode snmp_api \
  --unifi-base-url https://controller.example.com \
  --unifi-api-key "$UNIFI_API_KEY" \
  --mikrotik-base-url http://router.example.com/rest \
  --mikrotik-username "$MIKROTIK_USERNAME" \
  --mikrotik-password "$MIKROTIK_PASSWORD" \
  --snmp-version v2c \
  --snmp-community "$SNMP_COMMUNITY" \
  --type topology
```

```bash
bazel run //go/cmd/tools/mapper-baseline:mapper-baseline -- \
  --config /path/to/baseline.json
```

Saved controller configuration export is intentionally out of scope for this tool. If credentials are stored under Ash/AshCloak, they must be resolved by a ServiceRadar-managed export boundary and passed to this CLI as explicit runtime input.
