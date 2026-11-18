## MODIFIED Requirements

### Requirement: Source-Authoritative Identifiers Govern Identity
The system SHALL treat a current source-authoritative identifier (the Armis device id and the NetBox device id) as governing a record's identity: two records holding different current values of the same source-authoritative identifier type in one scope SHALL NOT be merged, whatever MAC or address evidence they share.
A value is current until it is retired by sustained absence from its source (requirement
"Source Identifiers Retire On Sustained Absence"). A retired value still bars a match at
ingest: an update carrying one value SHALL NOT be attached, through MAC or address evidence, to
a record that holds or held a different value of the same type in that scope. A retired value
SHALL give way only to the reconciler's corroborated succession (requirement "Corroborated
Source Identifier Succession"). Every other automatic merge path SHALL treat a retired value
exactly as it treats a current one.
An `integration_id` is not source-authoritative on its own, because providers do not mint it
stably per device; it never vetoes a match and governs identity only through the typed
provider id it accompanies.
When such a record reports a MAC or address that a different device holds, the
source-authoritative identifier decides the record's identity, and the MAC or address is
evidence only.

#### Scenario: Different Armis ids with a shared MAC stay separate
- **GIVEN** device X holds current Armis device id 1001 and device Y holds current Armis device id 2002
- **WHEN** an update for device Y reports a MAC that device X holds
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the conflict SHALL be recorded as an identity decision

#### Scenario: Different NetBox device ids with a shared MAC stay separate
- **GIVEN** device X holds current NetBox device id 1001 and device Y holds current NetBox device id 2002
- **WHEN** an update for device Y reports a MAC that device X holds
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the conflict SHALL be recorded as an identity decision

#### Scenario: A changed integration id re-attaches through the device's MAC
- **GIVEN** a device holds integration id G1 and a globally-unique MAC M
- **WHEN** the same source reports integration id G2 with MAC M
- **THEN** the update SHALL resolve to that device

#### Scenario: A new source id for a known MAC gets its own record at ingest
- **GIVEN** device X held Armis device id 1001, now retired, and holds MAC `00:00:5e:00:53:01`
- **WHEN** Armis reports device id 2002 with MAC `00:00:5e:00:53:01`
- **THEN** the update SHALL NOT be attached to device X
- **AND** a new record SHALL be created for Armis device id 2002
- **AND** a `source_override` identity decision SHALL name both records

#### Scenario: A retired id still blocks an uncorroborated automatic merge
- **GIVEN** device X holds only the retired Armis device id 1001 and device Y holds the current Armis device id 2002
- **AND** both hold MAC `00:00:5e:00:53:01` and nothing else corroborates them
- **WHEN** the scheduled duplicate backfill runs
- **THEN** devices X and Y SHALL NOT be merged

#### Scenario: A retired id gives way to corroborated succession
- **GIVEN** device X holds only the retired Armis device id 1001 and device Y holds the current Armis device id 2002
- **AND** both hold MAC `00:00:5e:00:53:01`, Armis reports the same first-seen time for both, and the pairing is one-to-one
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL converge into one record holding Armis device id 2002

### Requirement: Hostname Agreement Is Not Identity
The system SHALL NOT merge, adopt, claim, restore or resolve a record onto a device because a name or hostname agrees, on any automatic path or operator-initiated create or import, whatever else the two records hold or lack; a name or hostname match SHALL at most open a de-duplication review.
A name here is any label a source or an operator gives a device: its hostname, FQDN or first DNS
label, its OCSF device name, a hypervisor node or guest name, an AWX host name or `ansible_host`
label, or a manual or imported device's hostname. The rule covers sync writes at an address
another device holds, source-id succession and reactivation, AWX inventory hosts, hypervisor
enrichment, camera inventory, manual device add and CSV import, and remediation steps.
A name SHALL NOT count toward any corroboration a merge, adoption, claim or return requires.
Evidence that is not a name (a source-authoritative identifier, an agent id, a shared
universally administered MAC, a provider-scoped identifier, an address under requirement
"Address Is Evidence, Not Identity") SHALL decide exactly as it would if the names differed.
A name MAY still keep records apart or narrow a candidate set that non-name evidence must then
confirm; it SHALL never join two records.
Where a path would formerly have joined a record to a device on a name match, and the name is
the only thing joining them, the record SHALL be written by its other evidence, or as its own
device, and the path SHALL record a `policy_block` identity decision with reason
`hostname_agreement_not_identity` naming the record and the device the name matched, with the
name, the address if any and the path in its evidence. The matched device is the one candidate
the name matched: the live address holder whose name agrees; else the single live device in the
record's partition carrying the name; else, for manual device add and CSV import when no live
device carries the name, the single soft-deleted device in the partition carrying it. That
decision opens a de-duplication task. When the name matches more than one candidate, no task
SHALL be opened for it. A name match SHALL NOT restore a soft-deleted device, including the one
a review names.
In particular, a sync write of a new record holding a source-authoritative or integration
identifier at an address that a live device with the same name holds SHALL NOT adopt the
holder's uid and SHALL NOT be refused for lack of other evidence: the record SHALL be written as
its own device and the decision SHALL be recorded, so that the record never forks from the
holder without a review.

#### Scenario: Two existing devices with the same hostname stay separate
- **GIVEN** two live devices whose hostnames agree
- **WHEN** an update for one of them reports the address the other holds
- **THEN** the devices SHALL NOT be merged
- **AND** a `policy_block` identity decision SHALL name both devices

#### Scenario: Same-named devices at one address stay separate with a review
- **GIVEN** a live device X with hostname `host01.example.com` holding address `192.0.2.10`, with no source-authoritative identifier, agent or MAC
- **AND** a sync record that is not yet a device, carrying integration id `plugin-a:inst-1:obj-7`, hostname `host01.example.com` and address `192.0.2.10`
- **WHEN** the record is written
- **THEN** the record SHALL be written as its own device and SHALL NOT take device X's uid
- **AND** the address SHALL be decided by requirement "Address Is Evidence, Not Identity"
- **AND** a `policy_block` identity decision with reason `hostname_agreement_not_identity` SHALL name both devices and open a de-duplication task

#### Scenario: A new record colliding with a same-hostname address holder opens a review
- **GIVEN** a live device `host01.example.com` holding address `192.0.2.10`
- **WHEN** a NetBox record with hostname `host01.example.com` and address `192.0.2.10` arrives
- **THEN** the NetBox record SHALL be written as its own device
- **AND** a `policy_block` identity decision with reason `hostname_agreement_not_identity` SHALL name both devices

#### Scenario: A source-authoritative holder is not adopted on hostname agreement
- **GIVEN** a device holding an Armis device id at address A
- **WHEN** a NetBox record with the same hostname and address A arrives
- **THEN** the NetBox record SHALL be written as its own device
- **AND** a `policy_block` identity decision SHALL name both devices

#### Scenario: AWX host-label agreement opens a review and claims nothing
- **GIVEN** an agent-managed device `host01.example.com` holding address `192.0.2.20` and MAC `00:00:5e:00:53:21`
- **AND** an AWX host named `HOST01` with `ansible_host` `192.0.2.20`, no MAC and no Proxmox guest link
- **WHEN** the AWX inventory sync is ingested
- **THEN** the AWX record SHALL NOT be merged into the agent-managed device
- **AND** the agent-managed device SHALL NOT be claimed as the AWX host's inventory record
- **AND** a `policy_block` identity decision with reason `hostname_agreement_not_identity` SHALL name both records

#### Scenario: An AWX host still merges on a shared MAC
- **GIVEN** a device holding address `192.0.2.21` and MAC `00:00:5e:00:53:22`
- **AND** an AWX host with a different name whose variables carry MAC `00:00:5e:00:53:22` and `ansible_host` `192.0.2.21`
- **WHEN** the AWX inventory sync is ingested
- **THEN** the AWX record SHALL merge into that device on the shared MAC, as it would if the names agreed

#### Scenario: A manual re-add by hostname opens a review and revives nothing
- **GIVEN** a live device `host02.example.com` with no address, and a soft-deleted device `host02.example.com` deleted by an operator
- **AND** neither device holds address `198.51.100.12` or the uid the submission derives
- **WHEN** an operator adds `host02.example.com` with address `198.51.100.12`, manually or by CSV import
- **THEN** a new device SHALL be created for the submission
- **AND** the live device SHALL NOT be updated or merged, and the soft-deleted device SHALL remain deleted
- **AND** a `policy_block` identity decision with reason `hostname_agreement_not_identity` SHALL name the new device and the live device

#### Scenario: A manual re-add matching only a tombstone by hostname opens a review against it
- **GIVEN** a soft-deleted device `host08.example.com` deleted by an operator, and no live device carrying that hostname
- **AND** no device holds address `198.51.100.80` or the uid the submission derives
- **WHEN** an operator adds `host08.example.com` with address `198.51.100.80`, manually or by CSV import
- **THEN** a new device SHALL be created for the submission and the soft-deleted device SHALL remain deleted
- **AND** a `policy_block` identity decision with reason `hostname_agreement_not_identity` SHALL name the new device and the soft-deleted device

#### Scenario: A hypervisor or camera record is not resolved by name
- **GIVEN** a live device named `cam01` in partition `default`
- **AND** a camera or hypervisor record named `cam01` that carries no identifier, address or MAC another device holds
- **WHEN** the record is ingested
- **THEN** the record SHALL NOT be resolved to the device named `cam01`
- **AND** it SHALL be resolved by its other evidence, or written as its own device

### Requirement: Corroborated Source Identifier Succession
The scheduled reconciliation SHALL converge a record whose source-authoritative identifiers of a type are all retired (the predecessor) with the record holding a current identifier of that type in the same scope (the successor) when, and only when, all of the following hold: both report a universally administered, unicast MAC that is not all-zero or broadcast and that links the predecessor to no other record holding a current identifier of that type; their source observations agree on the source first-seen time; the pairing is one-to-one in both directions; and no distinct assertion or merge cooldown forbids the pair.
The record created first SHALL survive and SHALL take the current identifier. Source-owned
metadata SHALL come from the successor, facts carrying provenance SHALL merge per key by newest
provenance, and the survivor SHALL take the successor's address. The merge SHALL use reason
`source_succession`, SHALL pass through the merge engine's guards, and SHALL write a merge
audit row carrying the shared MAC, the agreeing first-seen time, the retired and current
identifiers and the collections that proved the retirement. An administrative unmerge of a
succession SHALL restore both records and SHALL record a distinct assertion for the pair.
Succession SHALL NOT run at ingest. A shared MAC alone SHALL NOT converge two records. A
hostname SHALL NOT corroborate succession, whatever the source times. Where the evidence is
weaker, the system SHALL record a `succession_review` identity decision, which opens a
de-duplication task, instead of merging: an equal hostname and first-seen time without a shared
MAC (`corroborated_without_mac`), a shared MAC and hostname without an agreeing first-seen time
(`overlapping_hostname`), a shared MAC without agreement on either field (`mac_only`), a MAC
shared with another current record (`shared_mac`), or a pairing that is not one-to-one
(`not_one_to_one`).

#### Scenario: MAC and first-seen time converge a re-identified asset
- **GIVEN** device X, created first, holds only the retired Armis device id 1001
- **AND** device Y holds the current Armis device id 2002
- **AND** both report MAC `00:00:5e:00:53:01`, no other record shares it, their hostnames differ, and Armis reports the same first-seen time for both
- **WHEN** the scheduled reconciliation runs
- **THEN** device Y SHALL be merged into device X with reason `source_succession`
- **AND** device X SHALL hold Armis device id 2002
- **AND** a merge audit row SHALL carry the shared MAC, the first-seen time, both ids and the collections that retired 1001

#### Scenario: A re-key whose only second factor is the hostname goes to review
- **GIVEN** device X, created first, holds only the retired Armis device id 1001
- **AND** device Y holds the current Armis device id 2002
- **AND** both report MAC `00:00:5e:00:53:01` and hostname `host01.example.com`, and no other record shares either
- **AND** Armis first saw id 2002 after it last saw id 1001, with a first-seen time of its own
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged
- **AND** a `succession_review` identity decision with reason `overlapping_hostname` SHALL open a de-duplication task naming both

#### Scenario: A shared MAC alone does not converge
- **GIVEN** device X holds only a retired Armis device id and device Y holds a current one
- **AND** they share MAC `00:00:5e:00:53:01`, and their hostnames and first-seen times differ
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged
- **AND** a `succession_review` identity decision with reason `mac_only` SHALL open a de-duplication task naming both

#### Scenario: Hostname and first-seen time without a shared MAC go to review
- **GIVEN** device X holds only a retired Armis device id and device Y holds a current one
- **AND** they share no universally administered MAC, and agree on hostname and first-seen time
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged
- **AND** a `succession_review` identity decision with reason `corroborated_without_mac` SHALL open a de-duplication task naming both

#### Scenario: Cloned machines sharing a MAC and a hostname do not converge
- **GIVEN** devices X and Y run copies of one image, and Armis reports both with MAC `00:00:5e:00:53:01` and hostname `host01.example.com`, X under id 1001 and Y under id 2002
- **AND** Armis stops reporting id 1001, which retires, and their first-seen times differ
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged
- **AND** a `succession_review` identity decision with reason `overlapping_hostname` SHALL open a de-duplication task naming both

#### Scenario: A MAC shared by cloned machines does not converge
- **GIVEN** device X holds only a retired Armis device id
- **AND** devices Y and Z each hold a current Armis device id
- **AND** all three report MAC `00:00:5e:00:53:01`
- **WHEN** the scheduled reconciliation runs
- **THEN** device X SHALL NOT be merged into either
- **AND** a `succession_review` identity decision with reason `shared_mac` SHALL open a de-duplication task

#### Scenario: A pairing that is not one-to-one goes to review
- **GIVEN** devices W and X each hold only a retired Armis device id, and device Y holds a current one
- **AND** both W and X share a linking MAC and an agreeing first-seen time with Y
- **WHEN** the scheduled reconciliation runs
- **THEN** no record SHALL be merged
- **AND** a `succession_review` identity decision with reason `not_one_to_one` SHALL open a de-duplication task naming all three

#### Scenario: A randomized MAC never corroborates succession
- **GIVEN** device X holds only a retired Armis device id and device Y holds a current one
- **AND** the only MAC they share is locally administered
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged by succession

#### Scenario: Succession waits for retirement
- **GIVEN** device X holds Armis device id 1001, absent from one exact collection, and device Y holds Armis device id 2002
- **AND** they share MAC `00:00:5e:00:53:01` and the first-seen time Armis reports
- **WHEN** ingest or the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged

#### Scenario: An unmerged succession stays apart
- **GIVEN** device Y was merged into device X by succession
- **WHEN** an administrator unmerges device Y
- **THEN** both records SHALL be restored with the identifiers each held before the merge
- **AND** a distinct assertion SHALL be recorded for the pair
- **AND** no later scheduled run SHALL merge them again

### Requirement: Retired Source Identifiers Are Reserved
The system SHALL keep resolving a retired source-authoritative identifier through the identifier archive. When a source reports a retired identifier again, the system SHALL return it to the record that held it when it was retired, or to that record's merge survivor, only when exactly one such record qualifies: the record is live or a tombstone that was not merged away, holds no unretired identifier of that type in the identifier's scope, whether or not the source still reports it, shares a universally administered unicast MAC with the update (its own, its MAC identifiers, its interface MACs, or the MAC the source last reported for the identifier before it retired), and agrees with the update on the source first-seen time. An identifier archived without its source times SHALL be compared on the record's first-seen time, for equality only. A hostname SHALL NOT qualify a record. Otherwise the system SHALL write the update as a new record, unless the usual resolution matches a record with no history of that type, and never to a record that held the identifier, and SHALL record a `source_id_reissued` identity decision naming both records, which opens a de-duplication task.
Returning an identifier SHALL resolve the update to that record and, in one transaction, SHALL
move its newest archive row back to the live identifier table, SHALL clear a `source_retired`
mark, SHALL restore a tombstone through the audited restore path, and SHALL record a
`source_id_reactivated` identity decision. When a read or the return fails, the system SHALL
withhold the updates carrying the identifier until the next sync run. Returning an identifier
SHALL NOT merge two live records.

#### Scenario: A retired id returns to its holder
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01`
- **AND** device X holds no current Armis device id
- **WHEN** Armis reports id 1001 again with MAC `00:00:5e:00:53:01` and the first-seen time it reported before
- **THEN** device X SHALL hold Armis device id 1001 in the live identifier table
- **AND** a `source_id_reactivated` identity decision SHALL be recorded

#### Scenario: A retired id reported for a different asset
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01`
- **WHEN** Armis reports id 1001 with MAC `00:00:5e:00:53:02` and a different hostname and first-seen time
- **THEN** a new record SHALL be created for the update
- **AND** device X SHALL NOT receive Armis device id 1001
- **AND** a `source_id_reissued` identity decision SHALL open a de-duplication task naming both records

#### Scenario: A retired id whose holder now holds a current id
- **GIVEN** device X held Armis device id 1001, retired, and now holds Armis device id 2002 in the live identifier table after a succession
- **WHEN** Armis reports id 1001 again
- **THEN** device X SHALL NOT receive Armis device id 1001
- **AND** a new record SHALL be created and a `source_id_reissued` identity decision SHALL name both records

#### Scenario: A retired id returns to a source_retired tombstone
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01`, and was soft-deleted with `deleted_reason` `source_retired`
- **WHEN** Armis reports id 1001 again with MAC `00:00:5e:00:53:01` and the first-seen time it reported before
- **THEN** device X SHALL be restored and SHALL hold Armis device id 1001 in the live identifier table
- **AND** the restore SHALL be recorded as a device revival

#### Scenario: A shared MAC and hostname do not return a retired id
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01` and hostname `host01.example.com`
- **WHEN** Armis reports id 1001 with MAC `00:00:5e:00:53:01`, hostname `host01.example.com` and a first-seen time that differs from the one it reported before
- **THEN** device X SHALL NOT receive Armis device id 1001
- **AND** a new record SHALL be created and a `source_id_reissued` identity decision SHALL open a de-duplication task naming both records

## ADDED Requirements

### Requirement: Name Attribution Is A Unique Last Resort
The system SHALL use a name or hostname to attribute an event, finding, readiness transition, credential lookup or topology endpoint to a device only after every non-name key the path carries (device uid, agent or workload identity, address, MAC or chassis id) has found nothing, and only when exactly one live device in the record's scope matches the name.
The scope is the record's partition when the record carries one, and every live device of the
deployment otherwise. A path SHALL NOT pick one of several matching devices by ordering, a
`LIMIT 1` read or first-entry-wins indexing. When no device or more than one device matches,
the record SHALL stay unattributed, and where the path records an attribution outcome today (an
unresolved topology endpoint, correlation telemetry, a finding's binding status) it SHALL
record that the name was ambiguous. A path SHALL NOT derive another key from a name, such as an
agent id formed from a hostname. Attribution by name SHALL NOT merge, adopt, restore or change
the identity of any device.

#### Scenario: A single same-named device is attributed
- **GIVEN** exactly one live device in partition `default` with hostname `node01.example.com`
- **WHEN** an event carrying only hostname `node01.example.com` and partition `default` is correlated
- **THEN** the event SHALL be attributed to that device

#### Scenario: Several same-named devices leave the record unattributed
- **GIVEN** two live devices in partition `default` with hostname `node01.example.com`
- **WHEN** an event carrying only hostname `node01.example.com` and partition `default` is correlated
- **THEN** the event SHALL NOT be attributed to either device
- **AND** the correlation outcome SHALL record that the name was ambiguous

#### Scenario: An address is used before a name
- **GIVEN** a live device X holding address `192.0.2.40` and a different live device Y with hostname `node02.example.com`
- **WHEN** an event carrying address `192.0.2.40` and hostname `node02.example.com` is correlated
- **THEN** the event SHALL be attributed to device X

#### Scenario: A hostname is not turned into an agent id
- **GIVEN** a runtime finding that carries a node name `node03` and no agent id
- **WHEN** the finding is correlated
- **THEN** no agent id SHALL be derived from `node03`
- **AND** the node name SHALL be used only as the last key under this requirement

#### Scenario: An ambiguous neighbor label stays an unresolved endpoint
- **GIVEN** live devices `sw01.site-a.example.com` and `sw01.site-b.example.com` in one partition, neither holding the neighbor's chassis MAC or management address
- **WHEN** the mapper reports an LLDP neighbor with system name `sw01`
- **THEN** the neighbor SHALL NOT be resolved to either device
- **AND** it SHALL be recorded as an unresolved endpoint with the ambiguous name

### Requirement: Integration Identifiers Are Not Name-Keyed
The system SHALL NOT mint, register or look up an `integration_id` keyed on a bare name or hostname: an integration identifier that ingest derives for a source object SHALL come from a plugin-supplied stable identifier (an explicit integration id, a serial or a stable hardware id), else from a universally administered unicast MAC, and otherwise the record SHALL carry no derived integration identifier and SHALL resolve by its other evidence.
A provider-issued object name that is scoped to its provider instance and cluster, such as a
Proxmox node in a v2 or v3 integration identifier, is a provider-scoped identifier and SHALL
remain identity. A name without that scope SHALL NOT be minted as, registered as or looked up as
an identifier (`IntegrationIdentity.ambiguous_name_keyed?/1`). Legacy name-keyed values, such as
AWX `awx:host:<name>` and ingest-minted `<source>:<kind>:<name>` values, SHALL NOT be emitted as
legacy lookup candidates or looked up. Existing rows holding such values SHALL stay where they
are as inert history, or be archived by a source retirement that already archives them, and
introducing this rule SHALL NOT merge or split any existing device. An update with no stable
identifier, no MAC of any kind and no address SHALL NOT be written as a new device, and SHALL be
counted as unresolved in the ingest outcome. A locally administered (randomized) MAC SHALL NOT
key an `integration_id`; an update whose only evidence is such a MAC is still written and
resolves under requirement "Randomized MACs Are Evidence Only". A source whose MACs rotate and
that supplies no stable identifier resolves by its other evidence, and MAY produce a new record
when its MAC changes.

#### Scenario: A serial-less plugin device without a stable id or MAC is not keyed by name
- **GIVEN** a plugin device-discovery record with hostname `host03.example.com` and address `198.51.100.30`, and no integration id, serial, hardware id or MAC
- **WHEN** the record is ingested
- **THEN** no `integration_id` SHALL be derived from `host03.example.com`
- **AND** the record SHALL resolve by its address

#### Scenario: A plugin-supplied stable id keys the record
- **GIVEN** a plugin device-discovery record carrying hardware id `HW-0001`, hostname `host04.example.com` and MAC `00:00:5e:00:53:41`
- **WHEN** the record is ingested
- **THEN** its derived `integration_id` SHALL be keyed on `HW-0001`

#### Scenario: A locally administered MAC does not key an integration id
- **GIVEN** a plugin device-discovery record with hostname `host09.example.com`, address `198.51.100.90` and only the locally administered MAC `02:00:5e:00:53:91`, and no stable id
- **WHEN** the record is ingested
- **THEN** no `integration_id` SHALL be derived from the MAC or the hostname
- **AND** the record SHALL resolve by its address

#### Scenario: A randomized-MAC record with no address is written but not keyed
- **GIVEN** a plugin device-discovery record with hostname `host10.example.com` and only the locally administered MAC `02:00:5e:00:53:a1`, and no stable id and no address
- **WHEN** the record is ingested
- **THEN** the record SHALL be written and SHALL NOT be counted as unresolved
- **AND** no `integration_id` SHALL be derived from the MAC or the hostname
- **AND** it SHALL resolve under requirement "Randomized MACs Are Evidence Only"

#### Scenario: A rotating MAC without a stable id is not anchored by name
- **GIVEN** a plugin device previously seen with hostname `host05.example.com` and MAC `00:00:5e:00:53:51`, and no stable id
- **WHEN** the plugin reports it with the same hostname and MAC `00:00:5e:00:53:52`
- **THEN** the hostname SHALL NOT tie the report to the earlier record
- **AND** the report SHALL resolve by its other evidence, and MAY become a new record

#### Scenario: A scoped Proxmox node name still resolves
- **GIVEN** a device holding the cluster-scoped Proxmox integration id for node `pve01` of cluster `cluster-a`
- **WHEN** the Proxmox enrichment reports node `pve01` of `cluster-a` again
- **THEN** the node SHALL resolve to that device through the scoped identifier

#### Scenario: An unscoped name-keyed identifier is rejected
- **GIVEN** a device holding the cluster-scoped Proxmox integration id for node `pve01` of cluster `cluster-a`
- **WHEN** an update carries only an unscoped Proxmox identifier naming node `pve01`
- **THEN** the unscoped value SHALL NOT be looked up or registered
- **AND** the update SHALL NOT resolve to the `cluster-a` node's device through it

#### Scenario: A legacy AWX name-keyed id is not looked up
- **GIVEN** a device holding the legacy identifier `awx:host:host06`
- **WHEN** an AWX host named `host06` is reported under its controller-scoped id with no other shared evidence
- **THEN** the legacy identifier SHALL NOT be looked up
- **AND** the AWX record SHALL NOT resolve to that device through it
