## ADDED Requirements

### Requirement: Agent-only tabs gated on hosts-an-agent predicate
The device detail page SHALL show agent-only tabs (Software) only when the device actually hosts a ServiceRadar agent — determined by the `ocsf_agents` device linkage (`DeviceStateData.agent?`) or a non-blank agent identity — or when real inventory/error data exists for the device. Tab visibility SHALL NOT be derived from a predicate that is true for every loaded device row (e.g. `is_map(device_row)`).

#### Scenario: Non-agent router
- **WHEN** a device is a router that hosts no agent (no `ocsf_agents` linkage, blank agent identity, no software inventory)
- **THEN** the Software tab is not rendered

#### Scenario: Agent host
- **WHEN** a device hosts an agent or has real endpoint-inventory data
- **THEN** the Software tab is rendered

### Requirement: Legible warning surfaces in dark theme
Warning-tone status banners SHALL use a foreground color with sufficient contrast against their tinted background (the bright `text-warning` foreground over `bg-warning/10`), not the `*-content` foreground meant for a solid fill, so warning banners are legible in the dark theme.

#### Scenario: Stale/mismatch endpoint-software banner
- **WHEN** the endpoint-software stale or row-mismatch warning banner renders in the dark theme
- **THEN** its text is legible (bright warning color), not dark-on-dark
