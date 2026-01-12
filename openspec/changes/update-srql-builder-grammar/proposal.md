# Change: Integrate SRQL builder for network sweep targeting rules

## Why
The network sweep UI needs a complete visual query builder for device targeting. The existing SRQL builder already supports stacking multiple filter conditions (implicit AND semantics), which covers production use cases like "devices with discovery_sources containing 'armis' in partition 'datacenter-1'". Rather than adding OR group syntax to the SRQL grammar, we can leverage the existing builder capabilities directly in the sweep targeting UI.

## What Changes
- Integrate the existing SRQL query builder component into the network sweep group targeting UI.
- Ensure the targeting rules UI supports the full set of device fields and operators already available in TargetCriteria (discovery_sources, partition, tags, IP CIDR/range, etc.).
- Update the criteria-to-SRQL conversion to handle all operators consistently.
- Add preview device counts using the generated SRQL query.

## Impact
- Affected specs: srql (documentation only - no grammar changes)
- Affected code: web-ng sweep criteria UI, targeting rules components
