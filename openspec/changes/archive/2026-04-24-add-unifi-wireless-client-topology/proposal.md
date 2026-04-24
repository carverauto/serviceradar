# Change: Add UniFi Wireless Client Topology

## Why
The live topology graph is missing large numbers of endpoints behind UniFi access points such as `UAP-nanoHD`, `U6LR`, and `U6 Mesh`.

Current mapper output proves the gap is upstream of `web-ng`: the UniFi poller emits AP uplinks, and SNMP-L2 emits switch-to-AP evidence, but the system does not emit controller-derived AP-to-client association links. As a result, the graph cannot represent wireless client attachment at all.

## What Changes
- Add UniFi controller topology extraction for wireless client associations.
- Publish controller-derived AP-to-client links as endpoint-attachment evidence.
- Define how wireless client links are keyed, deduplicated, and merged with existing SNMP/API topology evidence.
- Add tests covering UniFi wireless client association extraction and publication.

## Impact
- Affected specs: `network-discovery`
- Affected code: `go/pkg/mapper/ubnt_poller.go`, mapper topology publication/dedup, downstream topology consumers
