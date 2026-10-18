## ADDED Requirements

### Requirement: Devices Exposed To A CVE Are Answerable Fleet-Wide
The system SHALL answer "which devices are exposed to CVE-X" from current exposure facts as one SRQL query. It SHALL return one row per device, package identity and CVE whose assessment satisfies the exact actionable predicate (`status = active`, `assessment = confirmed`, `disposition = affected`), and it SHALL count distinct exposed devices without enumerating facts. Example: `in:exposure cve:CVE-2024-0001 sort:hostname:asc limit:200`.

#### Scenario: Exposed devices are listed
- **GIVEN** three devices have an actionable assessment for `CVE-2024-0001`
- **AND** a fourth device has only a `candidate` assessment for it
- **WHEN** an operator runs `in:exposure cve:CVE-2024-0001`
- **THEN** exactly the three devices are returned, each with its package, installed version, fixed version, CVSS, severity and KEV flag
- **AND** the candidate device is not returned

#### Scenario: Upgrade removes the device
- **GIVEN** a device is exposed to `CVE-2024-0001` through package version 1.0
- **WHEN** the package is upgraded to a fixed version and the matcher resolves the assessment
- **THEN** within the freshness target the device no longer appears in `in:exposure cve:CVE-2024-0001`
- **AND** the distinct-device count for the CVE decreases by one

#### Scenario: Host count without enumeration
- **WHEN** an operator runs `in:exposure cve:CVE-2024-0001 stats:"count_distinct(device_id) as hosts"`
- **THEN** the count is computed as a bitmap union over device ordinals
- **AND** the response reports the `as_of` time of the source it read

### Requirement: Exploited-Vulnerability Hosts In Contact With Threat Indicators Are Answerable
The system SHALL answer which hosts with a KEV-listed or high-EPSS exposure had observed connections to a currently matched threat-intel indicator within a bounded time window. The answer SHALL report the provenance of each contact. Examples: `in:exposure kev:true contacted_threat:true time:last_24h limit:100` and `in:observed_connections exposure_kev:true threat_matched:true time:last_24h sort:last_seen:desc limit:100`.

#### Scenario: KEV host contacted an indicator
- **GIVEN** a device has an actionable KEV exposure
- **AND** observed-connection evidence shows the device contacting `203.0.113.50` within the last 24 hours
- **AND** `203.0.113.50` has a live, matched threat-intel cache entry
- **WHEN** an operator runs `in:exposure kev:true contacted_threat:true time:last_24h`
- **THEN** the device is returned with the contact count, the last contact time and the contact provenance

#### Scenario: High EPSS filter
- **GIVEN** EPSS scores are available for the exposed CVEs
- **WHEN** an operator runs `in:exposure epss_score:>=0.5 contacted_threat:true time:last_24h`
- **THEN** only exposures whose CVE has an EPSS score of at least 0.5 are considered

#### Scenario: EPSS not available is explicit
- **GIVEN** no ingested feed carries EPSS
- **WHEN** an operator filters on `epss_score`
- **THEN** the response states `epss_unavailable`
- **AND** it does not return an empty result presented as "no matches"

### Requirement: Vulnerable Listening Processes Reached From The Internet Are Answerable
The system SHALL answer which listening processes whose owning package carries an actionable exposure received inbound connections from peers outside the deployment's local prefixes within a bounded time window. It SHALL join evidence to exposure on `(device, package identity)`. Example: `in:exposure listening:true inbound_internet:true severity:critical time:last_24h sort:cvss_score:desc limit:100`.

#### Scenario: Exposed listener reached from the internet
- **GIVEN** a process on a device listens on TCP 22, and its executable is owned by a package with a critical actionable exposure
- **AND** evidence shows inbound connections to TCP 22 on that device from `198.51.100.23`, which is outside the local prefixes, within the window
- **WHEN** an operator runs the example query
- **THEN** the exposure row is returned with the process name, the listener port, the count of distinct internet peers, and the provenance

#### Scenario: Internal-only inbound traffic does not qualify
- **GIVEN** the same listener received inbound connections only from addresses inside the local prefixes
- **WHEN** an operator runs the example query
- **THEN** the exposure row is not returned

#### Scenario: Unknown package ownership is never claimed as exposed
- **GIVEN** a listener whose executable has no resolved owning package
- **WHEN** an operator runs `in:exposure listening:true inbound_internet:true time:last_24h`
- **THEN** that listener is not reported as an exposure
- **AND** `in:observed_connections listening:true package_known:false time:last_24h` lists it as `package_unknown`

### Requirement: Blast Radius Of Exposed Devices Is Answerable Through Topology And BGP
The system SHALL expand a set of exposed seed devices into the devices that are adjacent to them in the topology graph within a bounded hop depth, and, when requested, into the devices addressed inside prefixes the seeds announce or carry as next hop. Each result SHALL carry its hop count, the device it was reached through, and the relation. Example: `in:exposure_blast_radius cve:CVE-2024-0001 depth:2 via:(topology,bgp) limit:500`.

#### Scenario: Topology neighbours are returned with their path
- **GIVEN** a router exposed to `CVE-2024-0001` with two downstream switches and ten hosts behind those switches
- **WHEN** an operator runs `in:exposure_blast_radius cve:CVE-2024-0001 depth:2`
- **THEN** the switches are returned at hop 1 and the hosts at hop 2, each with `via_device` and `relation`

#### Scenario: BGP prefixes extend the radius
- **GIVEN** an exposed BGP speaker announced `198.51.100.0/24` within the window
- **AND** two devices hold addresses in `198.51.100.0/24`
- **WHEN** an operator runs the query with `via:bgp`
- **THEN** both devices are returned with `relation = bgp_prefix` and the announcing seed as `via_device`

#### Scenario: Seed and node caps are explicit
- **GIVEN** the exposure filter resolves more than 500 seed devices
- **WHEN** an operator runs a blast-radius query
- **THEN** the query fails with an invalid-request error that asks for a narrower filter
- **AND** a traversal that reaches the 5,000-node cap returns `truncated = true`

### Requirement: Exposure Is Sliceable By Site Prefix Tag VLAN Owner And Workload
The system SHALL filter and group exposure by site, prefix tag, VLAN, owner, device tag and workload identity in the same query as the exposure predicate. It SHALL compute distinct-device counts per slice by bitmap intersection over device ordinals. Examples: `in:exposure severity:critical stats:"count_distinct(device_id) as hosts by site"`, `in:exposure kev:true tag:dmz`, `in:exposure vlan:120`, `in:exposure owner:"Platform Team"`, and `in:exposure namespace:payments time:last_24h`.

#### Scenario: Group exposure by site
- **GIVEN** critical exposures on devices whose addresses carry the prefix-tag sites `SITE01` and `SITE02`
- **WHEN** an operator runs `in:exposure severity:critical stats:"count_distinct(device_id) as hosts by site"`
- **THEN** one row per site is returned with its distinct exposed host count
- **AND** a device exposed to several critical CVEs is counted once per site

#### Scenario: Workload slicing needs a time window
- **WHEN** an operator runs `in:exposure namespace:payments` without `time:`
- **THEN** the query applies the default evidence window and states the window in the response
- **AND** workload membership is derived from processes observed owning the exposed package within that window

### Requirement: Exposure Trend Is Answerable Over Time
The system SHALL retain a daily snapshot of active exposure as device sets per CVE, severity and KEV flag, together with an append-only transition log. It SHALL answer per-day exposed-host counts, newly exposed counts, remediated counts and mean time to remediate for up to the history retention window. History SHALL be filterable only by the dimensions the snapshot retains (CVE, severity, KEV flag and device membership) and by the current-membership slices; package is not retained, and a history query filtering on package or on any other exposure field SHALL be rejected as unsupported. Example: `in:exposure_history kev:true time:last_90d stats:"count_distinct(device_id) as hosts by day"`.

#### Scenario: Ninety-day KEV trend
- **GIVEN** daily snapshots exist for the last 90 days
- **WHEN** an operator runs the example query
- **THEN** one row per day is returned with that day's distinct KEV-exposed host count

#### Scenario: Remediation is visible in the trend
- **GIVEN** a CVE exposed on 40 devices on day 1, and 10 of them remediated on day 2
- **WHEN** an operator queries `in:exposure_history cve:CVE-2024-0001 time:last_7d`
- **THEN** day 2 reports 30 exposed hosts and 10 remediated hosts

#### Scenario: Slicing history uses current membership
- **WHEN** an operator slices `in:exposure_history` by `site`
- **THEN** each day's device set is intersected with the site's current membership
- **AND** the response labels the slice membership as current

#### Scenario: Package is not a history dimension
- **WHEN** an operator runs `in:exposure_history package:openssl time:last_30d`
- **THEN** the query is rejected with an unsupported filter field error that names `package`

### Requirement: Observed Connections Form One Evidence Set With Provenance
The system SHALL maintain one observed-connection evidence set per device, hour, direction, protocol, service port and peer, fed by host-observed connection summaries and by network-observed flows. It SHALL report each evidence group's provenance as `host`, `network` or `corroborated`, computed across process keys so that one contact is never split into two provenances.

#### Scenario: Both sources corroborate
- **GIVEN** an agent reports an outbound TCP 443 connection from a device to `203.0.113.10` in an hour
- **AND** a NetFlow exporter reports the same contact in the same hour
- **WHEN** the evidence for that device and peer is queried
- **THEN** the contact is reported once with provenance `corroborated`, with host and network counts

#### Scenario: Unattributed network row does not split provenance
- **GIVEN** the host evidence row carries the process name and the network evidence row for the same contact has no process
- **WHEN** provenance is computed
- **THEN** the contact is `corroborated`, and the process from the host row is reported

#### Scenario: Provenance filter
- **WHEN** an operator runs `in:observed_connections provenance:host time:last_24h`
- **THEN** only contacts with host evidence and no network evidence are returned

### Requirement: Exposure Answers Do Not Require Network Flow Exporters
Every exposure use case except BGP blast radius SHALL be answerable from host-observed evidence alone. A deployment without flow exporters SHALL receive results whose provenance is `host`, and SHALL NOT receive an error or an empty result caused by the absence of network flows.

#### Scenario: Host-only deployment answers the internet-listener question
- **GIVEN** a deployment with agents and no flow exporters
- **AND** an agent reports accepted connections on an exposed listener from `198.51.100.23`
- **WHEN** an operator runs `in:exposure listening:true inbound_internet:true time:last_24h`
- **THEN** the exposure is returned with provenance `host`

#### Scenario: Host-only deployment answers the IOC question
- **GIVEN** a deployment without flow exporters, and a host peer that matches a threat-intel indicator
- **WHEN** an operator runs `in:exposure kev:true contacted_threat:true time:last_24h`
- **THEN** the KEV-exposed host that contacted the peer is returned

### Requirement: Host-Observed Peers Are Evaluated Against Threat Intelligence
The system SHALL admit internet-scoped peer addresses from host connection summaries to the same bounded threat-intel cache lookup that evaluates flow endpoints, deduplicated against flow endpoints. Exposure threat predicates SHALL read the matched set from that cache.

#### Scenario: Host peer is looked up without NetFlow
- **GIVEN** a host summary reports a peer `203.0.113.50` that no flow has ever carried
- **WHEN** the threat-intel refresh runs
- **THEN** `203.0.113.50` is evaluated against active indicators and cached

#### Scenario: Shared peers are looked up once
- **GIVEN** the same peer appears in both flows and host summaries
- **WHEN** the refresh runs
- **THEN** the peer is looked up once

### Requirement: Network-Only Connections To Fully Covered Hosts Raise An Evasion Signal
The system SHALL raise a `network_only` discrepancy signal when a network-observed connection side, after address translation, maps to exactly one agent-managed host whose agent attested complete, event-driven capture coverage for the connection's interval plus tolerance, and no host-observed connection or ownership lease matches it within the tolerance window. A candidate SHALL be evaluated only after the flow's late window has reached its cutoff with a final `no_owner` decision, as defined by *Late Binding Is Bounded And Never Rescans Flows*. Flows finalized early SHALL NOT produce candidates.

#### Scenario: Hidden connection is signalled
- **GIVEN** an agent attests complete event-driven coverage for 12:00-12:05 on a host with address `192.0.2.10`
- **AND** an unsampled flow record shows `192.0.2.10` exchanging payload with `203.0.113.77:4444` at 12:02
- **AND** neither the ownership index nor the host summaries contain a matching connection within the tolerance
- **WHEN** the evaluator processes the candidate
- **THEN** a `network_only` signal is recorded for the host with a confidence score, evidence references and the tolerance used

#### Scenario: Matching host evidence clears the candidate
- **GIVEN** the same flow, and a host summary reporting the connection at 12:02:03
- **WHEN** the evaluator processes the candidate
- **THEN** no signal is raised
- **AND** the candidate is recorded as suppressed with reason `host_matched`

#### Scenario: Late attribution cancels the candidate
- **GIVEN** a flow side was written unattributed, and a lease covering its time arrives within the late window
- **WHEN** the late window reaches its cutoff
- **THEN** no candidate is published for that side

### Requirement: Host-Only Connections Through Monitored Exporters Raise A Coverage-Gap Signal
The system SHALL raise a lower-severity `host_only` coverage-gap signal when host evidence shows internet-scoped connections from a device covered by an operator-defined expected-coverage rule, the rule's exporters were healthy for that hour, and no network evidence exists for those contacts. Under sampling, the computed probability that the exporter would have observed the contact SHALL be at least 0.999. Without an expected-coverage rule, no `host_only` signal SHALL be raised.

#### Scenario: Exporter misses covered traffic
- **GIVEN** an expected-coverage rule maps `192.0.2.0/24` to an unsampled exporter that was healthy for the hour
- **AND** a host in `192.0.2.0/24` reports 500 connections to `203.0.113.0/24` with no network evidence
- **WHEN** the hourly evaluation runs
- **THEN** a `host_only` signal with low severity is recorded, grouped by the rule and the exporter

#### Scenario: Low expected sampling coverage suppresses
- **GIVEN** the exporter samples 1 in 4096 packets, and the host reports 20 packets for the contact
- **WHEN** the hourly evaluation runs
- **THEN** no signal is raised
- **AND** the candidate is recorded as suppressed with reason `sampling_expectation`

#### Scenario: Unhealthy exporter suppresses
- **GIVEN** the covering exporter sent no records during the hour
- **WHEN** the hourly evaluation runs
- **THEN** no `host_only` signal is raised for that hour
- **AND** the candidates are recorded as suppressed with reason `exporter_unhealthy`

### Requirement: Sampling Never Creates An Evasion Signal Alone
A `network_only` signal SHALL require at least one unsampled network record that contains host-originated packets. Candidates supported only by sampled records SHALL be recorded as suppressed with reason `sampled_only` and SHALL NOT be signalled or alerted. Inbound-only traffic, and host responses limited to TCP RST or ICMP unreachable, SHALL be suppressed as `unanswered_inbound` or `kernel_reject`.

#### Scenario: sFlow-only evidence is never a signal
- **GIVEN** an sFlow exporter with sampling rate 1024 reports packets between a fully covered host and `203.0.113.77`
- **AND** no host evidence matches
- **WHEN** the evaluator processes the candidate
- **THEN** no signal is raised
- **AND** the candidate is recorded with reason `sampled_only`

#### Scenario: Port scan against a closed port is not evasion
- **GIVEN** an unsampled record shows inbound SYN packets to a covered host
- **AND** the only host-originated packets are TCP RST
- **WHEN** the evaluator processes the candidate
- **THEN** it is recorded with reason `kernel_reject` and no signal is raised

### Requirement: Agent Health Lag And Backpressure Suppress Coverage Claims
A coverage claim SHALL hold only for intervals whose attestation reports `complete = true` (zero kernel event loss, zero budget-shed ownership events, summaries aggregated no further than the `peer_ip` level, no agent restart, publish lag within bound, and no backpressure), and whose received summary row count equals the attested count. A candidate in any other interval, in a missing interval, or on an ownership shard that is warming SHALL be recorded as suppressed with its reason and SHALL NOT be signalled.

#### Scenario: Budget shedding voids the claim
- **GIVEN** an agent's attestation for 12:00-12:01 reports 30 lease renewals shed by the event budget
- **WHEN** a candidate in that interval is evaluated
- **THEN** it is recorded with reason `coverage_incomplete`

#### Scenario: Aggregated summaries void the claim
- **GIVEN** an agent's summaries for an interval reached the `service` aggregation level because the agent exceeded its summary cap
- **WHEN** a candidate in that interval is evaluated
- **THEN** it is recorded with reason `coverage_incomplete`

#### Scenario: Missing attestation voids the claim
- **GIVEN** no attestation for the candidate's interval arrives within the evaluation deadline
- **WHEN** the deadline passes
- **THEN** the candidate is recorded with reason `coverage_unknown`

#### Scenario: Summary rows still in flight
- **GIVEN** an attestation states 120 summary rows, but only 100 have been received when the evaluator runs
- **WHEN** the candidate is evaluated
- **THEN** the evaluator waits until the deadline for the remaining rows
- **AND** it records `summary_incomplete` if they never arrive

### Requirement: Coverage Claims Require Event-Driven Capture
An agent SHALL claim complete coverage only for intervals in which its socket lifecycle capture is event-driven. Intervals captured by polling, by procfs fallback or in a degraded mode SHALL be attested with `complete = false`. The attestation SHALL state whether coverage spans all network namespaces or only the host namespace.

#### Scenario: Polling agent never claims coverage
- **GIVEN** an agent whose capture runs in procfs polling mode
- **WHEN** it attests an interval
- **THEN** `capture_mode = polling` and `complete = false`
- **AND** candidates on its host are recorded with reason `not_event_driven`

#### Scenario: Pod address requires namespace coverage
- **GIVEN** an agent attests `netns_scope = host`
- **AND** a candidate's address belongs to a pod on that host
- **WHEN** the candidate is evaluated
- **THEN** it is recorded with reason `netns_not_covered`

### Requirement: Address Translation Is Resolved Before Evaluation
The evaluator SHALL map a network-observed address to a host only when the address is the host's own attested address, or when it resolves through the public endpoint (VIP) map or a node-SNAT entry to exactly one backend for the flow's time. Records from exporters marked as outside a NAT boundary SHALL NOT source candidates unless that resolution succeeds. Unresolvable or multi-backend translations SHALL be recorded as suppressed with reason `unresolved_translation`.

#### Scenario: VIP resolves to one backend
- **GIVEN** a flow to public VIP `198.51.100.80:443`, which the VIP map resolves to exactly one backend host at the flow's time
- **WHEN** the candidate is evaluated
- **THEN** it is evaluated against that backend's coverage, with the translation factor applied to its confidence

#### Scenario: VIP with several backends is not attributed
- **GIVEN** the VIP resolves to three backends
- **WHEN** the candidate is evaluated
- **THEN** it is recorded with reason `unresolved_translation`

### Requirement: Clock Skew Is Bounded By The Tolerance Window
The matching tolerance SHALL equal a configured base (default 5 seconds) plus the absolute agent clock offset reported in the attestation plus the exporter's estimated clock skew. Host and network intervals SHALL be compared by overlap after the tolerance is applied. When either clock's sync state is unknown, or the combined skew exceeds the configured maximum (default 30 seconds), the candidate SHALL be recorded as suppressed with reason `clock_unbounded`.

#### Scenario: Skewed but bounded clocks still match
- **GIVEN** an agent reports a clock offset of 3 seconds and the exporter skew estimate is 1 second
- **AND** the host reports the connection 8 seconds after the flow start
- **WHEN** the candidate is evaluated
- **THEN** the tolerance is 9 seconds, the host evidence matches, and no signal is raised

#### Scenario: Unsynchronized agent clock suppresses
- **GIVEN** an attestation reports clock sync state `unknown`
- **WHEN** a candidate in that interval is evaluated
- **THEN** it is recorded with reason `clock_unbounded`

### Requirement: Shared And Multi-Homed Addresses Are Not Attributed To One Host
The evaluator SHALL NOT attribute a network-observed address to a host when the address dimension shows more than one device holding it during the tolerance-extended interval, or when the address is a known shared address (VIP, anycast, VRRP). It SHALL evaluate a multi-homed host only on addresses present in its agent's attested address set.

#### Scenario: Reused DHCP address is not attributed
- **GIVEN** `192.0.2.30` moved from device A to device B during the candidate's interval
- **WHEN** the candidate is evaluated
- **THEN** it is recorded with reason `shared_address`

#### Scenario: Unattested secondary address is not covered
- **GIVEN** a host with two addresses, only one of which is in its agent's attested set
- **AND** a candidate on the other address
- **WHEN** the candidate is evaluated
- **THEN** it is recorded with reason `address_not_attested`

### Requirement: Discrepancy Signals Carry A Deterministic Confidence Score
Each discrepancy signal SHALL carry a confidence in [0, 1] computed only from stored inputs as the product of an evidence factor, a translation factor and a temporal-margin factor. The signal SHALL include the factors and their inputs. Signals at or above the configured incident threshold (default 0.85) SHALL be eligible for alerting; signals below it SHALL be stored and queryable but SHALL NOT alert.

#### Scenario: Strong direct evidence alerts
- **GIVEN** a direct-address candidate with an unsampled payload-bearing host-originated record, placed well inside the attested coverage
- **WHEN** it is scored
- **THEN** the confidence is 1.0 and the signal is alert-eligible

#### Scenario: Weak combination stays below threshold
- **GIVEN** an ACK-only host-originated record (evidence factor 0.9) resolved through a VIP (translation factor 0.9)
- **WHEN** it is scored
- **THEN** the confidence is 0.81, the signal is stored, and no alert is raised at the default threshold

#### Scenario: Score is reproducible
- **WHEN** a stored signal's inputs are rescored
- **THEN** the same confidence is produced

### Requirement: Suppressed Candidates Are Recorded With Their Reason
The evaluator SHALL record every evaluated candidate that does not become a signal with exactly one suppression reason from a closed vocabulary. It SHALL export per-reason counts on the JetStream metrics pipeline, so that a detector that suppresses everything is distinguishable from one that sees nothing.

#### Scenario: Suppressions are queryable
- **WHEN** an operator runs `in:connection_discrepancies outcome:suppressed time:last_24h stats:"count() as n by reason"`
- **THEN** one row per suppression reason is returned with its count

#### Scenario: Silence is distinguishable from blindness
- **GIVEN** no signals were raised in the last 24 hours
- **WHEN** an operator inspects the per-reason suppression counts and the candidate count
- **THEN** a zero candidate count and a high `coverage_unknown` count are distinguishable

### Requirement: Exposure State Is A Primary Key Fact Table Fed By Assessment Transitions
The system SHALL store current exposure in a StarRocks Primary Key table keyed `(device_ord, cve_ord, pkg_ord)`. The table SHALL be written only by an EventWriter processor from assessment transitions consumed from JetStream. Writes SHALL be conditional on `transition_seq`, which increases per fact in commit order, so that duplicate or reordered transitions never overwrite newer state. Each fact SHALL record the `transition_xid` of the transaction that produced its state. Resolution SHALL set the fact's state to resolved. A purge SHALL physically remove facts that have been resolved for longer than 7 days.

#### Scenario: Reordered transitions keep the newest state
- **GIVEN** transitions with sequence 10 (resolved) and 9 (active) for the same fact are delivered in the order 10, 9
- **WHEN** both are applied
- **THEN** the fact remains resolved

#### Scenario: Redelivery is idempotent
- **WHEN** the same transition is delivered twice
- **THEN** the fact is unchanged by the second delivery

#### Scenario: A published transition becomes a fact
- **GIVEN** a synthetic actionable transition for an invented device, CVE and package is published on the transitions subject
- **WHEN** EventWriter consumes it
- **THEN** a fact row with that key, state and `transition_seq` is readable from `exposure_facts`

#### Scenario: A rolled-back assessment change creates no fact
- **GIVEN** an assessment change whose CNPG transaction rolls back
- **WHEN** the outbox relay and EventWriter have run past that point
- **THEN** no transition is published for it, and no fact row for its key exists

### Requirement: Exposure Bitmaps Are Derived Views, Never The System Of Record
Roaring bitmap sets of devices (per CVE, per severity and KEV flag, and per device summary) SHALL be derived by asynchronous materialized views or scheduled jobs from the fact table and SHALL NOT be written directly. SRQL SHALL read a bitmap view only for aggregate and set queries, and only while its last refresh is within the staleness budget. Otherwise it SHALL read the fact table. Only append-only daily snapshots MAY use an Aggregate `BITMAP_UNION` table.

#### Scenario: Stale view falls back to the fact table
- **GIVEN** the CVE bitmap view's last refresh is older than the staleness budget
- **WHEN** an operator counts hosts exposed to a CVE
- **THEN** the count is computed from `exposure_facts`, and the response's `as_of` reflects the fact table

#### Scenario: View and fact table agree
- **GIVEN** a refreshed view
- **WHEN** a verification compares the view's per-CVE device count with a direct distinct count over the active facts
- **THEN** they are equal

### Requirement: Exposure Identifiers Use Collision-Free Dictionaries
Device ordinals SHALL come from `platform.device_fleet_ordinals`. CVE ordinals for identifiers of the form `CVE-YYYY-N` with N below 10^7 SHALL be `YYYY * 10^7 + N`; every other advisory identifier SHALL receive an ordinal of at least 10^12 from a sequence dictionary. Package identity and package-version ordinals SHALL come from sequence dictionaries. Hash-derived ordinals, including `bitmap_hash`, SHALL NOT be used. Ordinals SHALL be allocated by the producer before publishing, never by EventWriter.

#### Scenario: Deterministic CVE ordinal
- **WHEN** `CVE-2024-0001` is mapped
- **THEN** its ordinal is `20240000001` on every installation and across rebuilds

#### Scenario: Non-conforming identifier uses the dictionary
- **WHEN** an advisory identifier `CVE-2024-12345678` (sequence of 10^7 or more) is mapped
- **THEN** it receives a dictionary ordinal of at least 10^12

#### Scenario: Merge retires the losing ordinal
- **GIVEN** device A merges into device B, and A's ordinal is tombstoned
- **WHEN** the merge completes
- **THEN** every fact for A's ordinal is resolved and A's address intervals are closed
- **AND** B's assessments are published under B's ordinal

### Requirement: Flows And Host Evidence Map To Devices Through An Address Dimension
The system SHALL maintain a StarRocks address dimension mapping `(partition, ip)` to `device_ord` with validity intervals, address source, a shared flag, an agent-attested flag, and the prefix tags and site of the address. It SHALL be fed from inventory address changes and agent address leases through JetStream. The EventWriter flow tier SHALL hold a bounded in-memory validity history per address, fed from the same stream and retained for the maximum accepted flow delay plus the late window. It SHALL resolve each flow endpoint against the intervals covering the flow's observation time, never against the address's current holder, and stamp per-side device ordinals and resolutions at ingest. An endpoint whose observation interval is covered by more than one device SHALL be `ambiguous`, and one older than the retained history SHALL be `outside_history` and counted; neither SHALL carry an ordinal. Late re-resolution SHALL use the same time-based lookup.

#### Scenario: Address change closes the previous interval
- **GIVEN** `192.0.2.30` maps to device A
- **WHEN** inventory reports `192.0.2.30` on device B
- **THEN** A's interval is closed, B's interval is opened, and flows observed afterwards carry B's ordinal

#### Scenario: Delayed flow after readdressing keeps the original holder
- **GIVEN** `192.0.2.30` belonged to device A until 12:01 and to device B from 12:01
- **WHEN** a flow observed at 12:00:00-12:00:40 is ingested at 12:02
- **THEN** its side for `192.0.2.30` carries A's ordinal with resolution `resolved`

#### Scenario: Flow spanning a holder change is not attributed
- **GIVEN** the same address change
- **WHEN** a flow observed at 12:00:30-12:01:30 is ingested
- **THEN** its side for `192.0.2.30` has resolution `ambiguous` and no device ordinal

#### Scenario: Flow older than the retained history is counted
- **GIVEN** a flow whose observation time is older than the retained validity history
- **WHEN** it is ingested
- **THEN** its side has resolution `outside_history` and no device ordinal
- **AND** the `outside_history` count metric increases

#### Scenario: Flow device is the endpoint, not the exporter
- **GIVEN** a flow exported by a router between `192.0.2.10` (device H) and `203.0.113.5`
- **WHEN** it is ingested
- **THEN** the side for `192.0.2.10` carries H's ordinal, and the flow's exporter `device_uid` is unchanged

### Requirement: Small Inventory Dimensions Are Joined Through Narrow Catalog Views
Exposure queries SHALL obtain device names, VLAN, owner, device tags and the agent-managed flag only through the read-only views `platform.exposure_device_catalog` and `platform.exposure_device_tags_catalog`, over the `cnpg_platform` catalog, with column-scoped grants to the catalog reader role. Exposure queries SHALL NOT join assessment, package, advisory, coordinate, ordinal, agent or alert tables through the catalog. When the device views exceed the configured row threshold (default 250,000), the device dimension SHALL be mirrored into StarRocks through JetStream instead.

#### Scenario: Catalog allowlist rejects large tables
- **WHEN** a compiled exposure query references `cnpg_platform.platform.endpoint_vulnerability_assessments`
- **THEN** the catalog allowlist rejects it before execution

#### Scenario: Catalog unavailable is explicit
- **GIVEN** the catalog is disabled or unreachable
- **WHEN** an operator runs `in:exposure cve:CVE-2024-0001`
- **THEN** the exposure rows are returned with `hostname` marked `catalog_unavailable`
- **AND** names are not silently left empty

### Requirement: Exposure Is Rebuildable And Reconciled Against The Assessment Store
The system SHALL rebuild exposure facts through a generation snapshot of all actionable assessments, read in one transaction whose database snapshot `V` (`pg_current_snapshot()`) is recorded and carried on the end marker. Snapshot upserts SHALL carry each assessment's last `transition_seq` and `transition_xid`. Transitions whose transaction is not visible in `V` SHALL be applied as live transitions in any arrival order. Live transitions SHALL NOT change a fact's snapshot generation. On the end marker, the system SHALL resolve exactly the facts the snapshot did not touch whose `transition_xid` is visible in `V`. A sequence threshold SHALL NOT be used as the fence. The system SHALL also run a daily per-device reconciliation that compares actionable counts and an order-independent digest of `(cve_ord, pkg_ord)` between CNPG and StarRocks, re-snapshot every mismatched device, and export mismatch counts.

#### Scenario: Snapshot removes stale facts and keeps live updates
- **GIVEN** StarRocks holds a fact that CNPG no longer considers actionable
- **AND** a live transition arrives during the snapshot
- **WHEN** snapshot generation G completes
- **THEN** the stale fact is resolved, and the live transition's state is retained

#### Scenario: Transaction in flight during the snapshot keeps its result
- **GIVEN** a resolving transaction for an active fact has drawn its `transition_seq` but has not committed when the snapshot records `V`
- **AND** the snapshot therefore reads the assessment as active and upserts it with the previous sequence
- **WHEN** the resolving transaction commits and its transition is delivered either before or after the snapshot upsert and the end marker
- **THEN** the fact ends resolved

#### Scenario: Reconciliation can fail
- **GIVEN** a fact is deleted from StarRocks out of band
- **WHEN** the daily reconciliation runs
- **THEN** a mismatch is counted for that device, and a per-device snapshot restores the fact

### Requirement: Exposure Intelligence Requires StarRocks
Exposure entities, host connection evidence, coverage attestations and discrepancy records SHALL be stored only in StarRocks. Without StarRocks, the exposure SRQL entities SHALL return `{:error, :starrocks_required}`, and the UI SHALL report that state. CNPG assessments and the existing CNPG-backed `in:devices cve:` and `in:endpoint_vulnerability_assessments` queries SHALL remain fully functional without StarRocks.

#### Scenario: CNPG-only deployment
- **GIVEN** StarRocks is disabled
- **WHEN** an operator runs `in:exposure cve:CVE-2024-0001`
- **THEN** the response is `starrocks_required`
- **AND** `in:devices cve:CVE-2024-0001` still returns the exposed devices from CNPG

### Requirement: Exposure Freshness Meets Bounded Staleness Targets
The system SHALL meet these p99 freshness targets:
- an assessment commit becomes a visible fact within 120 seconds;
- a fact is reflected in the bitmap views within 180 seconds;
- an address change or address lease reaches the address dimension and the flow-tier validity history within 60 seconds;
- host evidence is visible within 120 seconds of its summary interval closing;
- a discrepancy record exists within 300 seconds of the later of its interval closing and its flow's late-window cutoff;
- the daily snapshot completes within 15 minutes of UTC midnight.
Every exposure SRQL response SHALL carry an `as_of` timestamp for each source it read.

#### Scenario: Transition visibility is measured
- **GIVEN** a synthetic assessment transition committed at time T
- **WHEN** the freshness probe queries the fact
- **THEN** the fact is visible by T + 120 seconds, and the measured delay is exported as a metric

#### Scenario: Response states its staleness
- **WHEN** any exposure query returns
- **THEN** the response includes `as_of` for the fact table or view, the evidence and the snapshots it used

### Requirement: Exposure Meets Fleet-Scale Capacity Targets
On the documented reference warehouse profile, using synthetic data from documentation address ranges only, the system SHALL meet these targets:
- **Scale:** 20,000 agent-managed hosts, 50 million active facts, and 50,000 exposed CVEs.
- **Ingest:** 5,000 transitions per second sustained, with a 1-million-transition burst drained within 10 minutes.
- **Host summaries:** the per-agent cap and volume set by *Hosts Report Per-Process Connection Summaries As Evidence*, with no further cap added here.
- **Evidence writes:** at most 25% of the flow row rate.
- **Query latency (p95):**
  - use case 1: 500 ms for rows and 1 s for counts by site;
  - use case 2 over 24 hours: 3 s;
  - use case 3 over 24 hours: 5 s;
  - use case 4 with 100 seeds at depth 2: 3 s;
  - use case 5: 2 s;
  - use case 6 over 90 days: 2 s;
  - discrepancy listing: 1 s;
  - each investigation pivot: 2 s.
- **Refresh:** each view refresh at 50 million facts within 60 seconds, and the daily snapshot within 5 minutes.

#### Scenario: Capacity run passes
- **WHEN** the synthetic capacity harness runs at the target scale
- **THEN** every latency, throughput and refresh target is met, and the results are recorded rounded in the change's design document

#### Scenario: Capacity run uses only invented data
- **WHEN** the harness generates devices, addresses, peers and CVEs
- **THEN** every address comes from `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` or `2001:db8::/32`, and every name is invented

### Requirement: Exposure Pipeline Health Is Observable
The system SHALL export, through the JetStream metrics pipeline with bounded labels:
- transition lag and throughput;
- snapshot and reconciliation outcomes and mismatch counts;
- view refresh duration and age;
- address-dimension size and shared-address count;
- evidence write rate and pre-aggregation ratio;
- candidate, signal and per-reason suppression counts;
- evaluator backlog.

#### Scenario: View refresh falling behind is visible
- **GIVEN** a bitmap view's refresh takes longer than its interval
- **WHEN** an operator reads the exposure health metrics
- **THEN** the view's age exceeds the staleness budget, and the metric shows it

### Requirement: Exposure Evidence And History Follow Warehouse Retention
Exposure evidence (observed connections, coverage attestations) and exposure history (daily snapshots, the transition log, discrepancy records) SHALL be governed as warehouse retention datasets that are configured as database-backed operator settings. The defaults SHALL be 90 days for evidence and 365 days for history. Current exposure facts SHALL NOT be subject to time-based retention, apart from the resolved-fact purge.

#### Scenario: Retention change applies without restart
- **WHEN** an operator lowers the exposure evidence retention to 30 days
- **THEN** evidence partitions older than 30 days are dropped without a restart
- **AND** active exposure facts are unaffected
