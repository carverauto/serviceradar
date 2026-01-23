# Change: Improve interface metrics timeseries charts

## Why
Interface bandwidth charts in web-ng are currently hard to interpret and do not match the clarity of the legacy React graphs. Operators need readable axes, gridlines, and correct rate deltas for SNMP counter-based traffic metrics.

## What Changes
- Add axes and gridlines to interface metrics timeseries charts for consistent time/rate interpretation.
- Compute per-second deltas from SNMP counter series (ifIn/OutOctets, ifHCIn/OutOctets) when rendering interface traffic charts.
- Align combined inbound/outbound traffic charts with the new axes and legend treatment.

## Impact
- Affected specs: build-web-ui
- Affected code: web-ng dashboard timeseries component and interface metrics LiveViews
