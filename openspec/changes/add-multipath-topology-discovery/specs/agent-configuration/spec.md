## ADDED Requirements
### Requirement: Multipath Discovery Configuration Schema
The agent configuration MUST support parameters for multipath topology discovery, including probing rate, TTL limits, and confidence levels.

#### Scenario: Valid multipath configuration
- **GIVEN** a discovery configuration with mode "Multipath"
- **THEN** it MUST conform to this structure:
```json
{
  "discovery_mode": "multipath",
  "multipath_params": {
    "max_ttl": 30,
    "probing_rate": 1000,
    "initial_probes_per_hop": 6,
    "confidence_level": 0.95,
    "protocol": "udp"
  }
}
```

#### Scenario: Default multipath values
- **GIVEN** a multipath discovery job without explicit parameters
- **THEN** it SHALL use defaults:
    - `max_ttl`: 30
    - `probing_rate`: 100 (pps)
    - `initial_probes_per_hop`: 6
    - `confidence_level`: 0.95
    - `protocol`: "udp"
