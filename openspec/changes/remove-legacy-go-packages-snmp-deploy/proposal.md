# Change: Remove legacy Go packages and standalone SNMP checker deployment

## Why
Multiple legacy Go packages appear unused since the Golang core was retired, and the SNMP checker now ships inside `serviceradar-agent`. We should remove dead code and stop building/shipping/deploying a standalone SNMP checker to reduce maintenance and deployment surface.

## What Changes
- Remove unused Go packages: `pkg/identitymap`, `pkg/http`, `pkg/db` (or unused portions), `pkg/sync`, `pkg/registry` after confirming they are no longer referenced.
- Stop building, publishing, and deploying a standalone SNMP checker artifact; the SNMP collector remains embedded in `serviceradar-agent`.
- Update Docker Compose and Helm resources to drop any SNMP checker services/images.
- Clean up build definitions (Bazel/Go modules) and docs referencing the removed packages or standalone SNMP checker.

## Impact
- Affected specs: `snmp-checker`
- Affected code: `pkg/identitymap`, `pkg/http`, `pkg/db`, `pkg/sync`, `pkg/registry`, build files, `docker-compose.yml`, `helm/`, Docker image targets
- Related issues: #2308, #2306, #2305, #2304, #2303
