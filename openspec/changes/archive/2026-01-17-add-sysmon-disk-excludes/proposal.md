# Change: Add sysmon disk exclude rules with collect-all default

## Why
Containerized agents can see multiple mounts, but the current sysmon configuration requires an explicit include list, which often results in only `/` being collected. We need a collect-all default with explicit exclude rules so operators can filter out mounts they do not want without losing visibility.

## What Changes
- Add `disk_exclude_paths` to sysmon configuration to allow operators to omit specific mount points.
- Treat an empty `disk_paths` list as "collect all disks", then apply the exclude list.
- Update the default sysmon profile to collect all disks with no excludes.
- Update the settings UI to expose disk exclusion rules and clarify the collect-all behavior.

## Impact
- Affected specs: sysmon-library, agent-configuration, build-web-ui
- Affected code: sysmon collector, sysmon profile defaults/compilation, agent config generation, sysmon settings UI
