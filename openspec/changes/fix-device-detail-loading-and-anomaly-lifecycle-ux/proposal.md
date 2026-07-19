# Change: Fix device detail loading and anomaly lifecycle UX

## Why
Device detail tabs currently disappear when a bounded presence probe times out, and opening the Interfaces or Flows tab can block the LiveView while expensive queries run. Resolved anomaly episodes also reuse their opening breach text, making a legitimate clear look contradictory.

## What Changes
- Preserve Interfaces and Flows navigation while availability is still being checked or a probe is inconclusive.
- Run interface inventory, favorite-interface metrics, and flow inventory outside the LiveView process with explicit loading and retry states.
- Bound the default device flow query to the documented recent window.
- Report the failing CPU subquery accurately when only the per-core SRQL request fails.
- Present anomaly opening and resolution state separately, explain merged flaps in operator language, and link to lifecycle documentation.

## Impact
- Affected specs: `build-web-ui`, `anomaly-detection`
- Affected code: Phoenix device detail LiveView, interface/flow loaders and components, sysmon metric sections, anomaly episode projection and modal
