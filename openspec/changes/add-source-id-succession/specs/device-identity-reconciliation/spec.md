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
- **AND** both hold MAC `00:00:5e:00:53:01` and the hostname `host01.example.com`, and the pairing is one-to-one
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL converge into one record holding Armis device id 2002

### Requirement: Address Is Evidence, Not Identity
The system SHALL NOT use an IP address, or a confirmed IP alias, as a device's identity: an address change SHALL NOT create a device record for a device that holds a strong identifier, and address evidence SHALL NOT merge two device records.
An address-only sighting attaches to the device that currently holds that address. DHCP moves
addresses between devices, so "same address" never implies "same device". Only a record that is
not yet a device may adopt an anchorless provisional seed (a sweep-created row) that holds its
address; an existing device takes the address by the newer-observation rule instead. A record
with archived identifier rows is anchored by them. When an
existing device takes the only address of an anchorless provisional seed -- one with no
identifier rows, current or archived, discovered only by sweeps and holding no other address -- the seed SHALL be
soft-deleted with `deleted_reason` `seed_released` in the same transaction, so a released seed
never stays live without an address.

#### Scenario: A known device changes address
- **GIVEN** a device identified by a strong identifier at address A
- **WHEN** an update carrying the same strong identifier arrives from address B
- **THEN** the update SHALL resolve to the existing device
- **AND** no new device record SHALL be created

#### Scenario: An address moves to a different device
- **GIVEN** device X held address A and has since moved to another address
- **AND** device Y, holding a different strong identifier, is now assigned address A
- **WHEN** updates for both devices are processed
- **THEN** devices X and Y SHALL remain separate records

#### Scenario: An address-only sighting attaches without merging
- **GIVEN** a live device currently holds address A
- **WHEN** a sighting with address A and no strong identifier arrives
- **THEN** the sighting SHALL attach to that device
- **AND** no device SHALL be created or merged because of it

#### Scenario: An existing device does not adopt a provisional seed
- **GIVEN** an anchorless provisional device, created by a sweep, holds address A and nothing else
- **AND** a device identified by a strong identifier already exists at another address
- **WHEN** an update for the existing device reports address A
- **THEN** the existing device SHALL take address A, as the newer observation
- **AND** the existing device SHALL NOT adopt the provisional record
- **AND** the provisional device SHALL release address A and be soft-deleted with `deleted_reason` `seed_released` in the same transaction
- **AND** an `ip_conflict` identity decision SHALL be recorded

#### Scenario: A provisional seed with more than an address stays live
- **GIVEN** a provisional device holds address A and an identifier row
- **WHEN** an identified device takes address A
- **THEN** the provisional device SHALL release address A and stay live
- **AND** an `ip_conflict` identity decision SHALL be recorded

### Requirement: Reconciliation Run Record
The system SHALL persist one durable record per scheduled reconciliation run. The record SHALL contain the run identifier, start and completion timestamps, duration, status, the count of duplicate identifier candidates, the duplicate, mergeable, and blocked component counts, the number of devices covered by blocked components, the size of the largest blocked component, the merges performed, the merges a merge guard refused, the blocked components and pairs skipped because their evidence was unchanged, the error count, the configured per-run merge cap, whether that cap was reached, the source succession merges performed, the succession candidates sent to review, skipped, and left for a later run, the configured per-run succession cap, the device membership of each blocked component, and the trigger that started the run.
A merge a merge guard refuses SHALL be counted as a blocked merge and SHALL NOT be counted as an error.

#### Scenario: Completed run is recorded
- **WHEN** a reconciliation run completes without raising
- **THEN** a run record SHALL be written with status `completed`
- **AND** the record SHALL carry every summary counter the run computed

#### Scenario: Cap-reached is recorded, not inferred
- **GIVEN** a reconciliation run whose merges reach the configured per-run cap
- **WHEN** the run completes
- **THEN** the run record SHALL carry the configured cap
- **AND** the run record SHALL record that the cap was reached

#### Scenario: Largest blocked component is retained
- **GIVEN** a run classifies one or more ambiguous components as blocked
- **WHEN** the run completes
- **THEN** the run record SHALL carry the size of the largest blocked component
- **AND** the run record SHALL carry the device uids belonging to each blocked component

#### Scenario: A blocked merge is not an error
- **GIVEN** a run whose only failed merges were refused by the source-authority guard
- **WHEN** the run completes
- **THEN** the run record SHALL count those merges as blocked merges
- **AND** its error count SHALL be zero

#### Scenario: Succession counts are recorded
- **GIVEN** a run whose succession pass merges a corroborated pair
- **WHEN** the run completes
- **THEN** the run record SHALL count the succession merge apart from the duplicate merges
- **AND** the run record SHALL carry the configured per-run succession cap

## ADDED Requirements

### Requirement: Source Identifiers Retire On Sustained Absence
The system SHALL retire a source-authoritative identifier that its source has stopped reporting: when the identifier was absent from at least N consecutive exact, activated collections of the source instance that owns its scope, all under one collection query, and was last reported at least T ago, the system SHALL move its identifier row to the identifier archive, with its provenance, in one transaction, and SHALL record a `source_id_retired` identity decision naming the device, the identifier and the collections that proved the absence.
N and T SHALL be operator settings, defaulting to 3 collections and 24 hours. Only exact,
activated collections SHALL count, whether as presence or as absence. Presence in one SHALL
reset the count, and a change of collection query SHALL restart it. An identifier type whose
source produces no exact collections, or an identifier whose scope cannot be tied to one source
instance, SHALL NOT be retired by absence. Retirement SHALL run after a collection activates and
never during ingest. A retirement pass that would affect more than a configured fraction of the
source instance's live records SHALL be refused, and the refusal recorded, unless an operator
overrides it for that pass. A source-authoritative identifier SHALL leave the live identifier
table only by retirement, merge or unmerge, and never by identifier garbage collection or a
cardinality cap.

#### Scenario: One absence does not retire an id
- **GIVEN** device X holds Armis device id 1001
- **WHEN** an exact collection activates without id 1001
- **THEN** device X SHALL still hold Armis device id 1001 in the live identifier table

#### Scenario: N absences within T do not retire an id
- **GIVEN** Armis device id 1001 was last reported 6 hours ago
- **WHEN** a third consecutive exact collection activates without it
- **THEN** id 1001 SHALL NOT be retired

#### Scenario: Sustained absence retires an id
- **GIVEN** Armis device id 1001 was absent from 3 consecutive exact, activated collections under one query
- **AND** it was last reported more than 24 hours ago
- **WHEN** the retirement pass runs after the third collection activates
- **THEN** its identifier row SHALL be in the identifier archive and not in the live identifier table
- **AND** a `source_id_retired` identity decision SHALL name the device, the identifier and the three collections

#### Scenario: A presence resets the count
- **GIVEN** Armis device id 1001 was absent from 2 consecutive exact collections
- **WHEN** the next exact collection reports it
- **THEN** its absence count SHALL return to zero

#### Scenario: A collection that is not exact counts neither way
- **GIVEN** Armis device id 1001 was absent from 2 consecutive exact collections
- **WHEN** a collection whose accounting is not exact activates without it
- **THEN** its absence count SHALL stay at 2

#### Scenario: A changed query restarts the count
- **GIVEN** Armis device id 1001 was absent from 2 consecutive exact collections under one query
- **WHEN** an exact collection under a different query activates without it
- **THEN** its absence count SHALL be 1

#### Scenario: A source without exact collections never retires
- **GIVEN** a device holds NetBox device id 1001 and NetBox produces no exact collections
- **WHEN** NetBox stops reporting it
- **THEN** the identifier SHALL NOT be retired by absence

#### Scenario: A mass retirement is refused
- **GIVEN** a retirement pass would retire more than the configured fraction of the source instance's live records
- **WHEN** the pass runs without an operator override
- **THEN** no identifier SHALL be retired
- **AND** the refusal SHALL be logged at error level with the counts and emitted as telemetry

#### Scenario: Identifier garbage collection does not remove a source id
- **GIVEN** a device holds Armis device id 1001, unseen past the identifier TTL
- **WHEN** identifier garbage collection or a cardinality cap runs
- **THEN** Armis device id 1001 SHALL remain in the live identifier table unless it was retired

### Requirement: Corroborated Source Identifier Succession
The scheduled reconciliation SHALL converge a record whose source-authoritative identifiers of a type are all retired (the predecessor) with the record holding a current identifier of that type in the same scope (the successor) when, and only when, all of the following hold: both report a universally administered, unicast MAC that is not all-zero or broadcast and that links the predecessor to no other record holding a current identifier of that type; their source observations agree on the source first-seen time, or on the normalized hostname when the source first saw the successor no earlier than it last saw the predecessor; the pairing is one-to-one in both directions; and no distinct assertion or merge cooldown forbids the pair.
The record created first SHALL survive and SHALL take the current identifier. Source-owned
metadata SHALL come from the successor, facts carrying provenance SHALL merge per key by newest
provenance, and the survivor SHALL take the successor's address. The merge SHALL use reason
`source_succession`, SHALL pass through the merge engine's guards, and SHALL write a merge
audit row carrying the shared MAC, the corroborating field, the retired and current
identifiers and the collections that proved the retirement. An administrative unmerge of a
succession SHALL restore both records and SHALL record a distinct assertion for the pair.
Succession SHALL NOT run at ingest. A shared MAC alone SHALL NOT converge two records. Hostname
agreement only corroborates, a hostname held by more than one current record of the source
SHALL NOT corroborate, and a hostname SHALL NOT corroborate when either time is missing. Where
the evidence is weaker, the system SHALL record a `succession_review` identity decision, which
opens a de-duplication task, instead of merging: an equal hostname and first-seen time without a
shared MAC, a shared MAC without agreement on either field, a shared MAC and hostname whose
source times fail the guard, a MAC shared with another current record, or a pairing that is not
one-to-one.

#### Scenario: MAC and hostname converge a re-identified asset
- **GIVEN** device X, created first, holds only the retired Armis device id 1001
- **AND** device Y holds the current Armis device id 2002
- **AND** both report MAC `00:00:5e:00:53:01` and hostname `host01.example.com`, and no other record shares either
- **AND** Armis first saw id 2002 after it last saw id 1001
- **WHEN** the scheduled reconciliation runs
- **THEN** device Y SHALL be merged into device X with reason `source_succession`
- **AND** device X SHALL hold Armis device id 2002
- **AND** a merge audit row SHALL carry the shared MAC, the hostname, both ids and the collections that retired 1001

#### Scenario: MAC and first-seen time converge a re-identified asset
- **GIVEN** device X holds only the retired Armis device id 1001 and device Y holds the current Armis device id 2002
- **AND** both report MAC `00:00:5e:00:53:01`, their hostnames differ, and Armis reports the same first-seen time for both
- **WHEN** the scheduled reconciliation runs
- **THEN** the two records SHALL converge into the one created first

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
- **AND** Armis stops reporting id 1001, which retires
- **AND** their first-seen times differ, and Armis first saw id 2002 before it last saw id 1001
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged
- **AND** a `succession_review` identity decision with reason `overlapping_hostname` SHALL open a de-duplication task naming both

#### Scenario: A hostname without source times does not corroborate
- **GIVEN** device X holds only a retired Armis device id and device Y holds a current one
- **AND** they share MAC `00:00:5e:00:53:01` and hostname `host01.example.com`, and their first-seen times differ
- **AND** the archived observation of device X carries no last-seen time
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
- **AND** both W and X satisfy the MAC and corroboration rules with Y
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
- **AND** they share MAC `00:00:5e:00:53:01` and hostname `host01.example.com`
- **WHEN** ingest or the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged

#### Scenario: An unmerged succession stays apart
- **GIVEN** device Y was merged into device X by succession
- **WHEN** an administrator unmerges device Y
- **THEN** both records SHALL be restored with the identifiers each held before the merge
- **AND** a distinct assertion SHALL be recorded for the pair
- **AND** no later scheduled run SHALL merge them again

### Requirement: Retired Source Identifiers Are Reserved
The system SHALL keep resolving a retired source-authoritative identifier through the identifier archive. When a source reports a retired identifier again, the system SHALL return it to the record that held it when it was retired, or to that record's merge survivor, only when exactly one such record qualifies: the record is live or a tombstone that was not merged away, holds no unretired identifier of that type in the identifier's scope, whether or not the source still reports it, shares a universally administered unicast MAC with the update (its own, its MAC identifiers, its interface MACs, or the MAC the source last reported for the identifier before it retired), and agrees with the update on the source first-seen time, or on the hostname (the one the source last reported or the record's own) when the update's first-seen time is no earlier than the identifier's archived last-seen time. An identifier archived without its source times SHALL be compared on the record's first-seen time, for equality only. Otherwise the system SHALL write the update as a new record, unless the usual resolution matches a record with no history of that type, and never to a record that held the identifier, and SHALL record a `source_id_reissued` identity decision naming both records, which opens a de-duplication task.
Returning an identifier SHALL resolve the update to that record and, in one transaction, SHALL
move its newest archive row back to the live identifier table, SHALL clear a `source_retired`
mark, SHALL restore a tombstone through the audited restore path, and SHALL record a
`source_id_reactivated` identity decision. When a read or the return fails, the system SHALL
withhold the updates carrying the identifier until the next sync run. Returning an identifier
SHALL NOT merge two live records.

#### Scenario: A retired id returns to its holder
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01` and hostname `host01.example.com`
- **AND** device X holds no current Armis device id
- **WHEN** Armis reports id 1001 again with MAC `00:00:5e:00:53:01`, hostname `host01.example.com` and the first-seen time it reported before
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

#### Scenario: A shared hostname from before the id was last seen
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01` and hostname `host01.example.com`, last seen by Armis at time T
- **WHEN** Armis reports id 1001 with MAC `00:00:5e:00:53:01`, hostname `host01.example.com` and a first-seen time earlier than T that differs from the one it reported before
- **THEN** device X SHALL NOT receive Armis device id 1001
- **AND** a new record SHALL be created and a `source_id_reissued` identity decision SHALL name both records

### Requirement: Retired Records Without A Successor
When a retirement leaves a live record holding only retired source-authoritative identifiers -- no agent identifier, no current source-authoritative identifier of another type, no identity-bearing observation within T, and not created by an operator -- the system SHALL mark it `source_retired` in the same transaction, and SHALL soft-delete it with `deleted_reason` `source_retired` once it has been marked for a grace period, releasing its address in the same transaction.
The grace period SHALL be an operator setting defaulting to 7 days. A marked record SHALL remain
a succession and reactivation candidate. A marked record named by an open de-duplication task
SHALL NOT be deleted while the task is open. A sweep, address-only or MAC-only sighting SHALL NOT
clear the mark, extend the grace period or restore the tombstone. The grace deletion pass SHALL
be bounded by the same mass guard as retirement. A record that an operator restores SHALL NOT be
marked again until another of its source-authoritative identifiers is retired. When a marked
record comes to hold an agent identifier or a source-authoritative identifier, by reactivation,
by a succession merge into it or by any ingest, the transaction that registers the identifier
SHALL clear the mark.

#### Scenario: A retired-only record is marked at once
- **GIVEN** device X holds only Armis device id 1001 and no other strong identifier from a current source
- **WHEN** id 1001 is retired
- **THEN** device X SHALL be marked `source_retired` in the same transaction

#### Scenario: A record with a current agent is not marked
- **GIVEN** device X holds Armis device id 1001 and an agent identifier that checked in an hour ago
- **WHEN** id 1001 is retired
- **THEN** device X SHALL NOT be marked `source_retired`

#### Scenario: The grace period ends in a soft delete
- **GIVEN** device X was marked `source_retired` 7 days ago and no open de-duplication task names it
- **WHEN** the device cleanup pass runs
- **THEN** device X SHALL be soft-deleted with `deleted_reason` `source_retired`
- **AND** device X SHALL no longer hold an address

#### Scenario: A pending review holds the deletion
- **GIVEN** device X was marked `source_retired` 7 days ago and an open de-duplication task names it
- **WHEN** the device cleanup pass runs
- **THEN** device X SHALL NOT be deleted

#### Scenario: A sweep does not keep a retired record alive
- **GIVEN** device X is marked `source_retired` and holds address `192.0.2.10`
- **WHEN** a sweep finds `192.0.2.10` answering, every hour until the grace period ends
- **THEN** device X SHALL still be soft-deleted when its grace period ends

#### Scenario: A new identifier clears the mark
- **GIVEN** device X is marked `source_retired`
- **WHEN** an ingest registers agent identifier `agent-01` on device X
- **THEN** device X SHALL NOT be marked `source_retired`
- **AND** the device cleanup pass SHALL NOT delete device X when the grace period ends

#### Scenario: A succession merge clears the survivor's mark
- **GIVEN** device X is marked `source_retired` after its Armis device id 1001 was retired
- **AND** device Y, created after X, holds the current Armis device id 2002 and passes the succession conditions with X
- **WHEN** the succession pass merges Y into X
- **THEN** device X SHALL hold Armis device id 2002
- **AND** device X SHALL NOT be marked `source_retired`

### Requirement: Retired Holders Do Not Keep An Address
A record holding a current source-authoritative identifier SHALL take an address from a holder that is marked `source_retired`, or whose source-authoritative identifiers are all retired, whatever their observation times. Between two identified records, the newer-observation rule SHALL compare the time of each record's last identity-bearing observation, which a sweep, an ARP or census sighting, or an address-only sighting SHALL NOT advance.
An identity-bearing observation carries a strong identifier as the device's own report: a source
sync carrying a current source-authoritative identifier, an agent check-in, or a discovery poll
of the device itself. A holder with no recorded identity-bearing observation SHALL be treated as
older than any record that has one.

#### Scenario: A retired holder yields the address
- **GIVEN** device X holds only the retired Armis device id 1001 and address `192.0.2.10`
- **AND** a sweep refreshed device X a minute ago
- **WHEN** an Armis update for the current id 2002 reports address `192.0.2.10`
- **THEN** the record holding id 2002 SHALL take address `192.0.2.10`
- **AND** device X SHALL no longer hold it

#### Scenario: A sweep refresh does not make a holder newer
- **GIVEN** device X's last identity-bearing observation is two days old and a sweep refreshed it a minute ago
- **AND** device Y's last identity-bearing observation is an hour old
- **WHEN** an update for device Y reports the address device X holds
- **THEN** device Y SHALL take the address

### Requirement: Blocked Components Are Not Retried Unchanged
The scheduled reconciliation SHALL record an evidence fingerprint for every component it blocks and for every pair a merge guard refuses on evidence -- covering the device set and the evidence that joined it, each device's live and archived identifiers, whether each device is deleted, its agent, identity state and identity source, the MACs of its interfaces, the distinct assertions covering the set, the surviving device where the guard's outcome depends on the direction of the merge, and the version of the reconciliation rules -- and SHALL skip, without re-attempting or re-recording it, a blocked component or pair whose fingerprint is unchanged since it was last blocked.
A change to any input of the fingerprint SHALL cause the component or pair to be evaluated again
on the next run. A blocked component or pair SHALL also be evaluated again once a bounded recheck
window, one day by default, has passed since it was last evaluated. A merge refused by the merge
cooldown SHALL NOT be skipped, because the cooldown depends on time rather than on evidence. A
skipped component SHALL be counted in the run record as blocked and unchanged, and a skipped pair
as a blocked merge that is blocked and unchanged.

#### Scenario: An unchanged blocked pair is skipped
- **GIVEN** a run blocked devices X and Y on a source-authority conflict
- **WHEN** the next run finds the same devices with the same identifiers
- **THEN** the merge SHALL NOT be attempted again
- **AND** the identity decision's occurrence count SHALL NOT increase
- **AND** the run record SHALL count the pair as a blocked merge that is blocked and unchanged
- **AND** its error count SHALL be zero

#### Scenario: An unchanged blocked component is skipped
- **GIVEN** a run blocked an ambiguous component of devices X, Y and Z
- **WHEN** the next run finds the same component with the same evidence
- **THEN** the component's identity decision SHALL NOT be recorded again
- **AND** the run record SHALL count the component as blocked and unchanged

#### Scenario: A blocked pair is re-checked after the recheck window
- **GIVEN** a run blocked devices X and Y on a source-authority conflict
- **WHEN** a run starts after the recheck window has passed with the same evidence
- **THEN** the merge SHALL be attempted again
- **AND** the identity decision's occurrence count SHALL increase by one

#### Scenario: A retirement re-opens a blocked component
- **GIVEN** a run blocked devices X and Y because X held Armis device id 1001
- **WHEN** id 1001 is retired and the next run starts
- **THEN** the component SHALL be evaluated again under the succession rules

#### Scenario: New reconciliation rules re-check every blocked component
- **GIVEN** blocked components recorded under one version of the reconciliation rules
- **WHEN** a release changes the rules and the next run starts
- **THEN** every blocked component SHALL be evaluated again once

### Requirement: IP Alias Rows Belong To One Device
The system SHALL keep an IP alias row per device: every device seen at an address SHALL have its own row of the address, filed under the device's partition, and only that device's sightings SHALL count toward confirming it.
Where several devices hold a confirmed alias of one address, a source sync, an agent check-in or
a mapper poll that resolves a device at the address SHALL handle every other holder by the rules
of requirement "IP Alias Resolution", and every lookup that resolves the address to one confirmed
holder SHALL take the most recently seen holder, then the one with the most sightings, then the
lowest device id. A merge of two devices that both hold a row of one address SHALL NOT fail on
it: the merged device's row SHALL be marked `replaced` by the survivor's, and a confirmation it
carried SHALL confirm the survivor's row when that row is pending or stale.

#### Scenario: A device seen at another device's alias gets its own row
- **GIVEN** device X holds a confirmed IP alias of `192.0.2.20`
- **WHEN** device Y is sighted at `192.0.2.20`
- **THEN** DIRE SHALL record the sighting on a pending alias row of `192.0.2.20` for device Y
- **AND** device X's row SHALL be left unchanged

#### Scenario: Sightings confirm only the sighted device's row
- **GIVEN** device X holds a pending IP alias of `192.0.2.21`
- **WHEN** device Y is sighted at `192.0.2.21` as often as the confirmation threshold
- **THEN** device Y's alias of `192.0.2.21` SHALL be confirmed
- **AND** device X's alias SHALL remain pending with its own sighting count

#### Scenario: Every identified holder of an address is handled
- **GIVEN** identified devices X and Y each hold a confirmed IP alias of `192.0.2.22`
- **WHEN** a source sync resolves device Z, identified by its source id, at `192.0.2.22`
- **THEN** the aliases of both X and Y SHALL be invalidated
- **AND** an `alias_invalidated` identity decision SHALL be recorded for each
- **AND** no two of the three devices SHALL be merged

#### Scenario: A device's own alias is not a conflict
- **GIVEN** devices X and Y each hold a confirmed IP alias of `192.0.2.23`, and Y holds a strong identifier of its own
- **WHEN** a mapper poll resolves device X at `192.0.2.23` by its interface MACs
- **THEN** device X's alias SHALL be left unchanged
- **AND** device Y's alias SHALL be invalidated

#### Scenario: Every lookup takes the same holder
- **GIVEN** devices X and Y each hold a confirmed IP alias of `192.0.2.24`, and Y's was seen more recently
- **WHEN** the sweep, a sync, the resolver or the mapper resolves `192.0.2.24` to one holder
- **THEN** each SHALL resolve it to device Y

#### Scenario: A merge folds an alias both devices hold
- **GIVEN** devices X and Y each hold an IP alias of `192.0.2.25`, X's confirmed and Y's pending
- **WHEN** X is merged into Y
- **THEN** the merge SHALL succeed
- **AND** X's row SHALL be marked `replaced` by Y's
- **AND** Y's row SHALL be confirmed
