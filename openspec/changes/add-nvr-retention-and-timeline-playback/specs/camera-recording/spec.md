## ADDED Requirements

### Requirement: Continuous segmented NVR recording
The system SHALL record a camera profile continuously into its assigned NVR member while an enabled continuous recording policy exists, independently of live viewers, as a chain of sealed blocks of at most 270 seconds, 8,100 frames or 12 MiB of media each, with exactly one block per ingest request.
Each request's media bounds SHALL stay strictly inside one NVR block, whose limits are 16 MiB and a configurable fragment count (default 150) with fragments of at least 2 seconds, so the NVR never rotates to a block identity that Core did not reserve. Handover between blocks SHALL cut at a keyframe when one arrives before the hard bound. Blocks larger than 16 MiB SHALL NOT be produced until the archive path supports multipart upload.

#### Scenario: Longest capture fits one block
- **GIVEN** the NVR's default of 150 fragments per block and the 2-second minimum fragment
- **WHEN** a capture reaches the 270-second ceiling
- **THEN** it SHALL seal as exactly one block
- **AND** the ingest response SHALL name only the reserved block

#### Scenario: Recording continues with no viewers
- **GIVEN** a camera profile has an enabled continuous policy and no open viewer
- **WHEN** the relay is idle of viewers for longer than the viewer idle timeout
- **THEN** the relay SHALL stay open under the recorder consumer lease
- **AND** blocks SHALL continue to be sealed on the policy's NVR member

#### Scenario: Keyframe-aligned handover
- **WHEN** a block reaches its soft bound and an IDR access unit arrives before the hard bound
- **THEN** the current request SHALL end before that access unit and the next request SHALL begin with it
- **AND** access units arriving during the handover SHALL be held in a bounded buffer rather than dropped

#### Scenario: NVR returns more than the reserved block
- **WHEN** an ingest response names any block other than exactly the reserved one
- **THEN** Core SHALL treat the outcome as an error requiring lookup
- **AND** SHALL NOT register any block that Core did not reserve

#### Scenario: Uncertain block outcome during a run
- **WHEN** an ingest request's outcome is unknown while the run still holds its recorder claim
- **THEN** Core SHALL look up the block at the original NVR member without resending media
- **AND** a sealed block SHALL be registered under the live claim, an absent block SHALL be recorded as a gap, and an incomplete or unresolved block SHALL end the run and be resolved by the reconciler

### Requirement: Bounded NVR block inventory
The NVR SHALL account for retained blocks through an incrementally maintained inventory ledger with a bounded boot rebuild and a bounded periodic audit, and SHALL enforce a per-volume block cap that is an install bound with a default of 131,072 and a ceiling of 262,144.
At the cap the NVR SHALL refuse new admission with a reported reason and SHALL NOT delete any block to make room.

#### Scenario: Volume reaches the block cap
- **WHEN** admitting another block would exceed the volume's block cap
- **THEN** the NVR SHALL refuse admission with `nvr_inventory_limit`
- **AND** the continuous coordinator SHALL record a gap with that reason and retry admission later
- **AND** status, reads, archive and receipt writes for existing blocks SHALL keep working

#### Scenario: Ledger disagrees with the volume
- **WHEN** the periodic audit finds a block whose files differ from the ledger
- **THEN** the NVR SHALL close admission and report the mismatch
- **AND** SHALL NOT repair, adopt or delete files

### Requirement: Automatic archive of sealed NVR blocks
The system SHALL archive every sealed block of a `local_and_archive` policy through the existing NVR archive contract when archiving is enabled, with bounded concurrency per member, retry with backoff for transient and unknown outcomes, and terminal reporting for conflicts.
Archive SHALL keep the local copy and SHALL be retried only from a pending or retryable state. A block SHALL be archived only when archiving is enabled and its policy stores `local_and_archive`; otherwise its catalog entry SHALL have archive state `not_required` and no archive job SHALL be enqueued, and a pending or retryable entry that no longer meets both conditions SHALL move to `not_required`.

#### Scenario: Provider is unavailable
- **WHEN** an archive attempt fails with a provider error or an unknown outcome
- **THEN** the system SHALL retry the same block with jittered exponential backoff
- **AND** a retry SHALL verify any objects the provider retained rather than overwrite them

#### Scenario: Member archive slots are busy
- **WHEN** the NVR answers that its archive slots are busy
- **THEN** the job SHALL be deferred without counting as a failed attempt

#### Scenario: Receipt conflict
- **WHEN** the NVR reports a receipt for a different destination or the block exceeds the archive object limit
- **THEN** the catalog entry SHALL be marked terminally failed with the error class
- **AND** SHALL NOT be retried automatically
- **AND** an operator-visible alarm SHALL be raised and remain until an operator resolves the entry

### Requirement: Recorded gaps with reasons
The system SHALL record every interval in which an enabled continuous policy did not produce sealed footage as a gap row with its reason and time basis, and SHALL measure gaps inside one recording run exactly from relay sequence numbers and media timestamps.
Intervals when recording was disabled or unscheduled SHALL be reported as not scheduled, not as gaps.

#### Scenario: Contiguous handover
- **WHEN** the next block's first relay sequence immediately follows the previous block's last sequence
- **THEN** no gap SHALL be recorded and the blocks SHALL be marked contiguous

#### Scenario: Frames dropped during handover
- **WHEN** relay sequences are skipped between two blocks of one run
- **THEN** a gap SHALL be recorded with its exact media duration and the reason `handover_overflow` or `keyframe_wait`

#### Scenario: Storage refuses admission
- **WHEN** the NVR refuses admission for capacity, inventory or recovery reasons
- **THEN** a gap SHALL be recorded with the refusal class until recording resumes

### Requirement: Labelled time basis for recorded footage
The system SHALL position recorded footage on a wall-clock timeline only through an explicit stored time basis and SHALL NOT present receipt-derived time as capture time.
With the `received` basis, a block's wall-clock position SHALL derive from Core's receipt time of the run's first access unit plus media-timestamp offsets, its uncertainty SHALL be stored as unmeasured, and the run SHALL re-anchor when observed receipt time drifts from the anchored estimate by more than 2 seconds. A block's immutable clock identity SHALL NOT change after reservation.

#### Scenario: Timeline labels received time
- **WHEN** a user views footage recorded with the `received` basis
- **THEN** times SHALL be labelled as received times
- **AND** the API SHALL report the basis and an unmeasured uncertainty rather than zero

#### Scenario: Camera clock drifts
- **WHEN** a block's observed receipt time differs from its anchored position by more than the drift tolerance
- **THEN** the run SHALL re-anchor at that block
- **AND** the timeline SHALL mark the boundary as re-anchored without recording a media gap

### Requirement: Core catalog of sealed NVR blocks
The system SHALL register each sealed NVR block as one catalog entry, created only in the same transaction that freezes the block's canonical descriptor, either under its original live recorder claim or by the reconciler's historical freeze under Core's retained reservation authority, and SHALL record the block's camera, profile, media and timeline ranges with their time basis and the state of its local and archive copies.
Catalog registration SHALL be create-only per storage identity and block key. A block SHALL NOT be cataloged as sealed or playable on the strength of on-disk evidence alone. The catalog SHALL also admit a quarantined entry, after the NVR confirms the move into its quarantine partition: a new row for a block or journal whose seal cannot be verified or recovered or that has no Core authority, with camera, profile, policy and run fields empty where the reservation and journal do not provide them; or the existing sealed row of a block whose registered archive binding is absent from retained history or ended for a compromise-class reason, keeping its frozen descriptor. A quarantined entry SHALL carry the reason, the quarantine receipt, the bytes and, when it archives, the archive state of its quarantine-destination copy; it SHALL NOT be played, and when its camera and interval are known its interval SHALL appear on the timeline as a gap with reason `quarantined`, otherwise it SHALL be listed on the health tab.

#### Scenario: Registration after seal
- **WHEN** a continuous run or bounded capture receives a sealed result for its reserved block
- **THEN** Core SHALL fetch the canonical descriptor from the NVR, freeze it and create the catalog entry in one transaction
- **AND** an exact retry SHALL return the existing entry while a different descriptor SHALL be refused as a conflict

#### Scenario: Block with no Core authority
- **GIVEN** a block on an NVR volume that matches no Core reservation and no reserved predecessor
- **WHEN** the reconciler examines it
- **THEN** the system SHALL NOT freeze, adopt or play it
- **AND** SHALL quarantine it under a quarantined catalog entry with its quarantine receipt, raise an alarm and list it for an operator decision

#### Scenario: Legacy upload path
- **WHEN** the older archive upload path requests a lease on a block stored on an NVR member
- **THEN** the request SHALL be refused

### Requirement: No stranded NVR footage
The system SHALL bring every block on an NVR volume, within a bounded time after its writer retires, to a terminal outcome of the drain, and the reconciler SHALL keep working a block until it reaches one. A block that does not archive, because its camera policy is `local_only` (including while an archive destination is configured for other cameras) or because it was made `not_required` when archiving was turned off, SHALL end at its local catalog entry with its index receipt persisted, or, for a bad seal, at its local quarantine receipt. A block that archives (archiving enabled and the policy stores `local_and_archive`) SHALL end only at a verified archive receipt or, for a bad seal, a verified quarantine-destination receipt. A quarantined block with no known camera policy (unattributable, or its policy cannot be determined) SHALL follow the deployment: when archiving is enabled it SHALL end only at a verified quarantine-destination receipt, and otherwise at its local quarantine receipt. Nothing else SHALL end the drain. A block or journal whose seal cannot be verified or recovered, or that has no Core authority, SHALL be quarantined: moved to a quarantine partition on the same volume and given a catalog entry in the quarantined state with its reason and receipt, retained, counted in usage, in the inventory ledger and in a quarantined-bytes figure, never playable, never selected by budget, age, full policy, object retention or reaper, and removed only by an explicit audited operator disposition of that catalog entry; when it archives, an archive job SHALL copy it to a quarantine prefix of the destination and SHALL be retried until its quarantine-destination receipt is verified. The interval it fails to cover SHALL be recorded as a gap with reason `quarantined` when its camera and interval are known. A sealed block SHALL be judged against the generation, archive binding and recorder grant valid when it was sealed, as add-edge-production-time-admission defines, and SHALL NOT be refused only because the current binding or generation changed.
A periodic reconciler SHALL compare each member's inventory with the Core catalog and SHALL adopt a block only under Core's retained reservation authority: the reservation row created under the live recorder fence before the block existed, matching storage identity, block key and verified journal identity including the clock, unchanged fence history, retired writer, and a ready recovery state. A block the NVR rotated into without a reservation SHALL be adopted only when its reserved predecessor in the same recorder epoch and clock epoch is adopted, its sequence was never allocated, and its journal identity differs from the predecessor's only in sequence. Incomplete journals SHALL be recovered through the existing explicit recovery to their last committed fragment before adoption. A block SHALL NOT be reclaimed while it is unreconciled.

#### Scenario: Uncertain capture later reconciled
- **GIVEN** a capture ended uncertain, its reserved block row is `open_local` and its claim has expired
- **WHEN** the reconciler finds that block sealed on the reserved storage with a journal identity equal to the row's identity
- **THEN** it SHALL freeze the descriptor historically and create the catalog entry
- **AND** it SHALL enqueue archive only when archiving is enabled and the block's policy stores `local_and_archive`; otherwise the entry SHALL have archive state `not_required` and no archive job SHALL be enqueued
- **AND** a concurrent live freeze of the same block SHALL resolve as an exact retry or a conflict, never two entries

#### Scenario: Second rotated block adopted
- **GIVEN** a capture rotated into a second block that Core never reserved
- **WHEN** the reconciler finds the next block key derived from the reserved predecessor's identity, with no Core row for that capture identity and a journal identity differing only in sequence
- **THEN** it SHALL create the missing reservation row from the predecessor's fields, freeze it historically and catalog it
- **AND** a block whose identity or clock epoch does not match SHALL be treated as having no Core authority

#### Scenario: Archive outage then catch-up
- **GIVEN** the archive destination is unreachable for several hours while recording continues
- **WHEN** the destination becomes reachable again
- **THEN** every cataloged unarchived block SHALL be archived by retried jobs without operator action
- **AND** during the outage the settings view SHALL show the unarchived count, bytes and oldest unarchived age, and an alarm SHALL be raised once the oldest unarchived block exceeds the alarm threshold
- **AND** none of those blocks SHALL be reclaimed before its archive copy is verified

#### Scenario: Incomplete journal recovered
- **WHEN** the reconciler finds an incomplete journal for a reserved block whose writer is retired
- **THEN** it SHALL recover the block to its last committed fragment through the existing explicit recovery and catalog it
- **AND** SHALL record the lost tail as a gap with reason `incomplete_tail`

#### Scenario: Unrecoverable journal is quarantined
- **WHEN** explicit recovery of a reserved block fails verification
- **THEN** the system SHALL quarantine the block or journal and record its quarantine receipt on a quarantined catalog entry
- **AND** SHALL record a gap with reason `quarantined`, the verification class and the reserved interval
- **AND** SHALL raise an alarm and show the quarantined bytes on the health tab
- **AND** SHALL NOT play it or remove it until an operator records an audited disposition, at any usage
- **AND** the alarm SHALL remain until that disposition removes it

#### Scenario: Quarantine copy retried until verified
- **GIVEN** archiving is enabled and a quarantined block's camera policy stores `local_and_archive`
- **WHEN** its copy to the quarantine prefix fails
- **THEN** the archive job SHALL retry it until the quarantine-destination receipt is verified
- **AND** the drain SHALL NOT end at the local quarantine receipt

#### Scenario: Unattributable block follows the deployment
- **GIVEN** a block with no Core authority and no known camera policy is quarantined
- **WHEN** archiving is enabled for the deployment
- **THEN** it SHALL be copied to the quarantine destination and its drain SHALL end only at the verified quarantine-destination receipt, retried like any other archive job
- **AND** when archiving is not enabled, its drain SHALL end at its local quarantine receipt

#### Scenario: Local-only camera ends at its local catalog entry while a destination exists
- **GIVEN** archiving is enabled for other cameras and one camera's policy is `local_only`
- **WHEN** that camera's sealed block is cataloged with its index receipt persisted
- **THEN** the drain SHALL end for that block and no archive job SHALL be enqueued
- **AND** if that camera's block has a bad seal, its local quarantine receipt SHALL end the drain

#### Scenario: Archive binding changes while blocks are pending
- **GIVEN** cataloged blocks pending archive under the binding active when they were registered
- **WHEN** an operator changes the archive binding
- **THEN** those blocks SHALL still be archived under their registered binding
- **AND** only blocks registered afterwards SHALL use the new binding

#### Scenario: Unreconciled block under disk pressure
- **WHEN** a member is under storage pressure and holds unreconciled blocks
- **THEN** the system SHALL NOT reclaim them
- **AND** SHALL stop admission with a gap if headroom cannot otherwise be restored

#### Scenario: History unresolved after a restore
- **WHEN** a storage lifetime awaits current-history reconciliation after a deliberate restore
- **THEN** the reconciler SHALL NOT adopt or dispose of any block on it
- **AND** SHALL raise an alarm while the pause lasts longer than its threshold

### Requirement: Capacity-driven local tier with archiving
The system SHALL treat local NVR storage as a bounded cache with a byte budget and SHALL select local copies for eviction only by this table: a quarantined entry (q) SHALL never be selected for space or by age, SHALL always be pinned with its quarantined bytes, and takes precedence over the archive state; every other entry is keyed by the local copy's archive state: (a) `verified`, or `deleted` for any reason (object retention, object reaper or operator; local only after archive expiry or reaping): evictable for space, age ceiling the maximum local age; (b) `not_required` (local-only footage): evictable for space only when the local-only full policy `overwrite_oldest` is recorded and otherwise pinned, age ceiling the local-only maximum age whatever the full policy; (c) `pending`, `failed_retryable` or `failed_terminal` (unarchived), `deleting` until the retention job confirms absence and moves the entry to `deleted`, and `missing`: never selected for space or by age, always pinned. These rows SHALL cover every archive state, and a new archive state SHALL NOT be written until it is assigned to one of them. An entry left in `deleting` by a crash SHALL be resumed by the next retention pass, which repeats the idempotent delete and absence check and then marks it `deleted`. Every row SHALL also require that the block is cataloged and reconciled, that the local copy is not a hold's pinned copy, and that the member's recovery gate and current-history state permit destructive operations.
When usage reaches the high-water mark the system SHALL evict the space-evictable rows only, in one oldest-first order by block time across kinds (a) and (b), until usage is at or below the low-water mark; a copy older than its kind's age ceiling SHALL be evicted when that ceiling is limited. An unlimited maximum local age SHALL leave space eviction as the only eviction of kind (a) and SHALL NOT affect kind (b). A kind (a) block whose archive copy was deleted SHALL NOT count as unarchived and SHALL NOT be re-archived automatically. When the installation does not set a budget, the budget SHALL be derived from the volume size minus a reserve rather than a fixed default.

#### Scenario: Budget-driven eviction with archiving on
- **GIVEN** a member's usage reaches the high-water mark and its oldest blocks are archive-verified
- **WHEN** the retention pass runs
- **THEN** the oldest such local copies SHALL be evicted through audited dispositions until usage is at or below the low-water mark
- **AND** their archive copies SHALL remain playable

#### Scenario: Operator keeps footage locally with no age limit
- **GIVEN** archiving is on, the maximum local age is set to unlimited and archive retention is 30 days
- **WHEN** an unheld block is 31 days old and usage is below the high-water mark
- **THEN** its archive copy SHALL be deleted by object retention and its local copy SHALL be kept
- **AND** the catalog SHALL record the block as local only after archive expiry
- **AND** the effective window SHALL be shown as the budget-bound figure
- **AND** when usage reaches the high-water mark that local copy SHALL be evicted with the other evictable local copies, oldest first

#### Scenario: Maximum local age reached first
- **GIVEN** usage is below the high-water mark
- **WHEN** a kind (a) local copy exceeds the maximum local age
- **THEN** that local copy SHALL be evicted

#### Scenario: Local-only block on a mixed member is not aged by the maximum local age
- **GIVEN** archiving is enabled, one camera's policy is `local_only`, the maximum local age is 24 hours and the local-only maximum age is unlimited
- **WHEN** an unheld `not_required` block is 25 hours old and usage is below the high-water mark
- **THEN** the block SHALL be kept

#### Scenario: Local-only block past the local-only maximum age on a mixed member
- **GIVEN** archiving is enabled, one camera's policy is `local_only`, and the local-only maximum age is 7 days
- **WHEN** an unheld `not_required` block is 8 days old and usage is below the high-water mark, under `overwrite_oldest`, under `stop_when_full` or with no full policy recorded
- **THEN** the block SHALL be evicted with reason `local_only_max_age` under each of those full policies

#### Scenario: Mixed member evicts a local-only camera's oldest block
- **GIVEN** archiving is enabled, one camera's policy on the member is `local_only`, `overwrite_oldest` is recorded, and that camera's block is the oldest evictable block
- **WHEN** usage reaches the high-water mark
- **THEN** that local-only block SHALL be evicted first through an audited disposition with reason `local_only_overwrite`
- **AND** eviction SHALL continue oldest first across local-only, archive-verified and archive-deleted blocks until usage is at or below the low-water mark

#### Scenario: Mixed member with stop when full counts local-only footage as pinned
- **GIVEN** archiving is enabled, one camera's policy on the member is `local_only`, and the full policy is `stop_when_full` or none is recorded
- **WHEN** the retention pass and the window calculation run
- **THEN** that camera's blocks SHALL NOT be evicted for space and SHALL count as pinned bytes in the effective window and the budget floor
- **AND** the page SHALL report that local-only cameras are consuming space that cannot be freed

#### Scenario: Pending upload is never selected
- **GIVEN** `overwrite_oldest` is recorded, one camera's policy is `local_only`, the archive destination is down, and the member's oldest cataloged, reconciled, unheld block is pending while a newer block is `not_required`
- **WHEN** usage reaches the high-water mark, or the pending block exceeds any age ceiling
- **THEN** the pending block SHALL NOT be evicted
- **AND** space eviction SHALL select the `not_required` block and kind (a) copies only

#### Scenario: Archive outage fills the volume and recording stops with an alarm
- **GIVEN** the archive destination is unreachable and new blocks stay unarchived
- **WHEN** usage approaches the budget
- **THEN** the system SHALL raise time-to-full alerts before the volume is full
- **AND** at the budget or reserve floor the NVR SHALL refuse admission and recording SHALL stop with a gap and a critical alert
- **AND** no unarchived block SHALL be evicted
- **AND** recording SHALL resume once archived blocks become evictable

### Requirement: Effective local window projection
The system SHALL compute and display, per NVR member and per kind of the local eviction table, how long local storage holds at the current recording rate, stating which bound applies: for the space-evictable kinds it SHALL solve the sum over kinds of rate times the smaller of the kind's age ceiling and T equal to the low-water bytes less pinned bytes for the lower end, and equal to the high-water bytes less pinned bytes for the upper end, and show each kind's window as the range between the smaller of its age ceiling and each T, a single 0 only when pinned bytes are at or above high water, where each rate is the larger of the trailing 15-minute and 6-hour sealed-byte rates of that kind. Pinned bytes SHALL be the bytes of the union of every local copy eviction cannot free, each block counted once, as partitioned in the design's effective-window definition (C1a); every other use of pinned bytes in this specification refers to that definition. When the blocks the window would retain exceed the volume's block cap, the system SHALL name the block cap as the binding bound, keep the footage, and show the time until admission stops as a separate figure. Every comparison of a window with an alert threshold or target SHALL use the lower, low-water end of the range. Time-to-full SHALL be reported as not filling when pinned bytes do not grow, or when every growing part has a limited age ceiling and its projected peak fits under the budget; otherwise it SHALL divide the budget less pinned bytes by the current growth rate of pinned bytes, never by ingest that eviction frees.
Before an operator saves a change to recording policies, profiles, member assignment or watermarks, the system SHALL show the projected window, the provider throughput needed against measured provider throughput (archive upload plus readback, about twice the media bytes verified), projected blocks per day against the block cap, and projected sessions against the member's session limit.

#### Scenario: Twenty cameras shrink the window and the operator is told before saving
- **GIVEN** a member holds about a day of footage for one camera
- **WHEN** an operator prepares to add nineteen more cameras to that member
- **THEN** before saving, the view SHALL show the projected local window in hours or minutes and warn when it is below the alert threshold
- **AND** SHALL report when the projected sessions exceed the member's session limit or the provider throughput needed exceeds measured provider throughput

#### Scenario: No ingest
- **WHEN** a member has no enabled recording policy
- **THEN** the view SHALL report that it is not recording rather than an unbounded window

#### Scenario: Local-only maximum age caps the window
- **GIVEN** a local-only member whose budget alone would hold about 60 days and whose local-only maximum age is limited to 7 days
- **WHEN** the window is shown
- **THEN** it SHALL be 7 days with the local-only maximum age named as the binding bound

#### Scenario: Mixed member window per kind
- **GIVEN** a member with a low-water budget of 67.2 GiB, `overwrite_oldest` recorded, nothing pinned, a maximum local age of 24 hours and an unlimited local-only maximum age, recording 500 kB/s that archives and 15 kB/s of local-only footage
- **WHEN** the window is shown
- **THEN** the archived footage SHALL show 24 hours bound by the maximum local age and the local-only footage about 22 to 29 days bound by the budget

#### Scenario: Time-to-full counts only pinned growth
- **GIVEN** a mixed member with a 90.2 GB budget, 72.2 GB low water and 81.2 GB high water under `stop_when_full`, with 82.8 GB pinned (7.4 GB of budget left), local-only footage at 15 kB/s and archived footage at 500 kB/s with archiving keeping up
- **WHEN** the window and time-to-full are computed
- **THEN** time-to-full SHALL be about 5.7 days and SHALL NOT raise the time-to-full alert
- **AND** the archived footage's window SHALL be 0, because pinned bytes exceed high water

#### Scenario: Pinned bytes between the water marks
- **GIVEN** the same member with 75 GB pinned
- **WHEN** the window is computed
- **THEN** the archived footage's window SHALL be 0 to about 3.4 hours, not a single 0
- **AND** a 1 hour window alert threshold SHALL be reported as not met, because the lower end is 0

#### Scenario: Block cap binds before the byte window
- **GIVEN** a 1 TiB volume with one 120 kbit/s camera, a byte window of about 570 to 641 days and a block cap of 131,072 blocks at 320 blocks per day
- **WHEN** the window is shown
- **THEN** the binding bound SHALL be the block cap and the time until admission stops SHALL be about 410 days from empty
- **AND** no block SHALL be deleted to stay under the cap

#### Scenario: Archived window kept while pinned bytes are small
- **GIVEN** the same member with 20 GB pinned
- **WHEN** the window and time-to-full are computed
- **THEN** the archived footage SHALL show 24 hours bound by the maximum local age and time-to-full SHALL be about 54 days

#### Scenario: Archive copy found changed keeps its local copy
- **GIVEN** object retention found an archive copy changed and marked it `missing`
- **WHEN** usage reaches the high-water mark or the local copy exceeds the maximum local age
- **THEN** the local copy SHALL NOT be evicted and SHALL count as pinned bytes

#### Scenario: Holds are counted once in pinned bytes
- **GIVEN** `overwrite_oldest` with 8 GB pending of which 2 GB is held, or `stop_when_full` with 20 GB of local-only footage of which 5 GB is held
- **WHEN** pinned bytes are computed
- **THEN** they SHALL be 8 GB and 20 GB respectively

#### Scenario: Age ceiling stops pinned growth
- **GIVEN** `stop_when_full`, a local-only maximum age of 7 days, 15 kB/s of local-only footage, 1.3 GB on disk, a 90.2 GB budget and nothing else pinned
- **WHEN** time-to-full is computed
- **THEN** it SHALL be reported as not filling

#### Scenario: Short history
- **WHEN** a member has less than 15 minutes of recorded history
- **THEN** the window SHALL be computed from the assigned profiles' observed bitrates and labelled as an estimate

### Requirement: Explicit local-only full policy
The system SHALL delete local-only footage (archive state `not_required`) for space only under an explicitly selected, audited full policy: `overwrite_oldest`, which makes local-only footage space-evictable in the local eviction table, or `stop_when_full`, under which local-only footage is pinned and recording stops at the budget. When no selection has been recorded, the system SHALL behave as `stop_when_full`. `overwrite_oldest` space eviction SHALL select local-only footage and other space-evictable copies only, never unarchived footage; in a deployment with no object storage every block is local-only footage.
The local-only retention period SHALL be a target that raises an alert when the effective window is below it and MAY be turned off, and the local-only maximum age SHALL default to an explicit unlimited state (keep until the volume is full) and, when limited, SHALL delete older unheld local-only footage under either full policy. Local-only footage SHALL be labelled as stored on unqualified local storage until local-copy qualification and registration exist for its storage lifetime.

#### Scenario: Local-only ring buffer evicts the oldest unheld block
- **GIVEN** an operator has confirmed `overwrite_oldest` and usage reaches the high-water mark
- **WHEN** the retention pass runs
- **THEN** the oldest space-evictable blocks of the local eviction table SHALL be deleted through audited dispositions until usage is at or below the low-water mark
- **AND** held blocks and unarchived blocks SHALL be skipped even when they are the oldest

#### Scenario: Local-only stop when full
- **GIVEN** the full policy is `stop_when_full` or no selection has been recorded
- **WHEN** usage reaches the budget
- **THEN** no local-only footage SHALL be deleted for space
- **AND** recording SHALL stop with a gap and a critical alert
- **AND** local-only footage older than a limited local-only maximum age SHALL still be deleted by age

#### Scenario: Held footage fills the budget
- **WHEN** held and unreconciled footage alone reach the budget under `overwrite_oldest`
- **THEN** recording SHALL stop with a gap
- **AND** a critical alert SHALL name the held bytes and the holds

#### Scenario: Retention target not met
- **WHEN** the local-only effective window is shorter than the retention target
- **THEN** an alert SHALL report the current window and the target

### Requirement: Local-only recording is a complete mode
The system SHALL support recording with no object storage as a complete mode: recording, cataloging, reconciliation, timeline, playback, holds, retention, settings and alerts SHALL work with archiving disabled and no archive destination, and every page SHALL state the local-only mode as a normal state rather than an error or an unconfigured state.

#### Scenario: Operator runs local-only with keep-until-full
- **GIVEN** archiving is disabled, no destination exists, the local-only maximum age is unlimited and the operator has confirmed a full policy
- **WHEN** cameras record continuously
- **THEN** footage SHALL be cataloged, playable on the timeline and holdable
- **AND** no archive job, backlog alert or destination prompt SHALL be raised
- **AND** footage SHALL be kept until usage reaches the high-water mark, where the confirmed full policy SHALL apply

#### Scenario: Settings page with no object storage
- **WHEN** an operator opens the recording settings with archiving disabled
- **THEN** the archive tab SHALL read "Local only: no object storage configured" as a normal state
- **AND** all local retention settings SHALL be editable

### Requirement: Operator-set local budget applied at runtime
The system SHALL let an operator set each NVR member's local byte budget and reserve from the settings UI, stored in CNPG per storage lifetime, and SHALL deliver them to the member over the existing pinned Core-to-NVR channel as a bounded, authenticated, versioned setting that the member persists beside its storage marker and applies to admission without a restart.
The applied budget SHALL NOT exceed the install ceiling or the measured volume capacity minus the reserve, Core SHALL refuse a budget below the member's pinned bytes as defined for the effective local window, a reserve SHALL NOT fall below the install reserve, a stale revision SHALL be refused, and a budget change SHALL NOT delete footage by itself. The member SHALL report the applied values and revision so the UI shows desired versus applied.

#### Scenario: Operator lowers the budget below current usage
- **GIVEN** a member's usage is above a newly saved budget that is still above its pinned bytes
- **WHEN** the member applies the new budget
- **THEN** admission SHALL stop until usage falls below the new high-water mark
- **AND** footage SHALL be removed only by eviction of evictable blocks through audited dispositions, never by the budget change itself

#### Scenario: Budget below pinned bytes
- **WHEN** an operator tries to save a budget below the member's pinned bytes
- **THEN** Core SHALL refuse the change and state the pinned bytes
- **AND** held bytes whose verified archive copy is the pinned copy SHALL NOT count toward that floor

#### Scenario: Desired versus applied budget differ
- **WHEN** a member is unreachable or refuses a saved budget
- **THEN** the view SHALL show the desired value, the applied value and revision, and the pending age or refusal reason
- **AND** the member SHALL keep admitting under its last applied value
- **AND** a pending or refused state lasting more than 10 minutes SHALL raise an alert

#### Scenario: Install ceiling lowered below a persisted budget
- **WHEN** a member restarts with an install ceiling below its persisted budget
- **THEN** it SHALL apply the install values, report the persisted setting as refused with the reason, and the view SHALL show the difference

### Requirement: Deduplicated storage alerts
The system SHALL raise NVR storage conditions through the platform's existing deduplicated, auto-clearing health-check path, per member: usage above high water with nothing evictable, effective window below the configured threshold, projected time-to-full below 4 hours (critical below 1 hour or when admission has stopped), oldest unarchived footage older than 1 hour when archiving is on, local-only retention target not met, held local copies that are the pinned copy or local-only footage that cannot be evicted filling the local budget, a held archive copy failing its re-check, effective object retention below configured retention, projected days to object capacity below 7 (not filling with an unlimited object budget; under a recorded `reap_oldest`, days until non-reapable bytes, meaning held archive copies, uploads in flight and quarantine objects, reach object high water; under `stop_archiving` or no recorded policy, days until usage reaches the hard limit at the measured archived-bytes rate), quarantined blocks, object usage at 75% and 90% of the hard limit, metered overage active, non-reapable bytes at object high water, and archive uploads paused for capacity; object checks SHALL fire before the first capacity deletion. Each object reaper run that deletes footage SHALL also publish an event with the bytes deleted and the resulting effective object retention.
Each condition SHALL clear when it no longer holds, and repeated evaluation of an unchanged condition SHALL NOT raise duplicates.

#### Scenario: Condition persists and then clears
- **WHEN** the effective window stays below the threshold for several passes and then recovers
- **THEN** one alert SHALL be raised and it SHALL clear when the window recovers

### Requirement: Application-managed object retention
The system SHALL expire archive copies itself through a dedicated retention credential role limited to DELETE and HEAD on the destination prefix, and SHALL NOT depend on provider lifecycle rules to expire recorded footage.
Without a selected retention credential, object retention SHALL be reported as not enforced and nothing SHALL be deleted. Neither object retention nor the reaper SHALL select the quarantine-destination copy of a quarantined entry. Expiry SHALL delete only the archive copy; a local copy that is still present SHALL be kept, recorded as local only after archive expiry and governed by the local budget and maximum local age.

#### Scenario: Archive copy expires
- **WHEN** an archive copy is older than its object retention and unheld
- **THEN** the system SHALL delete each of its objects and confirm by HEAD that each is absent before marking the copy deleted
- **AND** if its local copy is present, the local copy SHALL be kept, the entry SHALL be recorded as local only after archive expiry, and the local copy SHALL remain evictable by the local budget and maximum local age

#### Scenario: Versioned bucket
- **WHEN** the destination reports an object version
- **THEN** the system SHALL delete that exact version after matching its ETag and length to the receipt
- **AND** SHALL NOT treat a delete marker as deletion

#### Scenario: Object changed or locked
- **WHEN** an object's ETag or length differs from the receipt, or the provider refuses deletion for a lock
- **THEN** the system SHALL NOT delete it, SHALL record the condition, and SHALL report it

#### Scenario: Writer credential cannot delete
- **WHEN** only writer and reader credentials are selected
- **THEN** no object SHALL be deleted
- **AND** the view SHALL state that object retention is not enforced

### Requirement: Object-tier capacity budget
The system SHALL support an optional object-tier byte budget, unlimited by default, with high and low water marks and an explicitly selected capacity policy recorded with its confirming actor or plan terms: `reap_oldest`, which deletes the archive copies of the oldest unheld blocks from high water down to low water, or `stop_archiving`, which pauses archiving and keeps footage locally. When no policy has been recorded the system SHALL behave as `stop_archiving`.
With `reap_oldest`, the system SHALL delete only archive copies, oldest first, each deletion an audited disposition with reason `object_capacity` using the retention credential. A reaped block whose local copy still exists SHALL keep it; the catalog SHALL record the block as local only after archive reaping and the disposition SHALL record that the local copy remained. That local copy SHALL then be kind (a) of the local eviction table: kept until the local budget or the maximum local age requires eviction, oldest first, evictable and not pinned as unarchived, and never re-archived automatically. The recorded `reap_oldest` selection SHALL also authorize that later local eviction, which deletes the last copy, and the settings UI SHALL say so before the selection is recorded and SHALL show which footage exists only on local storage. Time-based archive retention SHALL still apply and whichever limit is reached first SHALL delete the archive copy. Held archive copies SHALL NOT be deleted. The system SHALL compute and show, per policy, the effective object retention from the shared calculation (see "Shared calculated retention and usage report") beside the configured archive retention, with the binding bound and the same what-if projection as the local window.

#### Scenario: Reaper keeps a fixed-size bucket within budget
- **GIVEN** the object budget is limited and `reap_oldest` has been confirmed
- **WHEN** object usage reaches the high-water mark
- **THEN** the archive copies of the oldest unheld blocks SHALL be deleted until usage is at or below the low-water mark
- **AND** an event SHALL report the bytes and blocks deleted and the resulting effective object retention

#### Scenario: Bucket full with a large local volume keeps local history
- **GIVEN** `reap_oldest` is confirmed, the maximum local age is unlimited and the local budget holds more footage than the bucket
- **WHEN** the reaper deletes the archive copy of a block whose local copy still exists
- **THEN** the local copy SHALL be kept and stay playable
- **AND** the catalog SHALL record the block as local only after archive reaping and the `object_capacity` disposition SHALL record that the local copy remained
- **AND** the settings page SHALL show that footage older than the bucket holds exists only on local storage
- **AND** the block SHALL NOT be archived again

#### Scenario: Reaped block later evicted locally
- **GIVEN** a block is local only after archive reaping and unheld
- **WHEN** local usage reaches the high-water mark and it is among the oldest evictable local copies
- **THEN** its local copy SHALL be evicted through an audited disposition with reason `budget`
- **AND** it SHALL NOT be treated as unarchived footage that blocks eviction

#### Scenario: Held block is neither reaped nor evicted
- **GIVEN** a hold covers the oldest block while object usage and local usage are both at their high-water marks
- **WHEN** the reaper and the local retention pass run
- **THEN** its archive copy SHALL NOT be reaped
- **AND** the copy the hold pins SHALL NOT be evicted; when its archive copy had already been reaped before the hold was placed, its local copy SHALL be pinned and kept

#### Scenario: Stop archiving when the bucket is full
- **GIVEN** the object budget is limited and the policy is `stop_archiving` or none has been recorded
- **WHEN** archiving the next block would exceed the object budget
- **THEN** archive jobs SHALL pause with blocks kept pending, recording SHALL continue locally, and an alert SHALL report usage and the projected days to object capacity
- **AND** no archived footage SHALL be deleted for capacity

#### Scenario: Held archive bytes alone exceed the budget
- **WHEN** held archive bytes alone reach the object high-water mark
- **THEN** archiving SHALL stop, recording SHALL continue locally, and a critical alert SHALL name the held bytes and the holds
- **AND** no held archive copy SHALL be deleted

#### Scenario: Effective object retention shown before saving
- **WHEN** an operator prepares to add cameras or change the object budget
- **THEN** the view SHALL show the projected effective object retention beside the configured archive retention and which of the two binds

### Requirement: Recording holds block deletion
The system SHALL let a permitted user place an investigation or export hold on a camera time range, serialized against deletion intents on the covered catalog entries in one transaction, and SHALL keep at least one verified copy of every covered block until the hold is explicitly released: the archive copy when it is verified, otherwise the local copy.
When the archive copy is verified, the hold SHALL pin it and the local copy SHALL remain evictable by the local budget and age rules; in local-only mode, or before the archive copy is verified, the hold SHALL pin the local copy, and the pin SHALL move to the archive copy when it becomes verified. A deletion intent committed before a hold SHALL win, and the hold SHALL report those blocks as unavailable rather than include them.

#### Scenario: Hold on archived footage does not consume the hot tier
- **GIVEN** a hold covers blocks whose archive copies are verified
- **WHEN** the local tier reaches its high-water mark
- **THEN** the held blocks' local copies MAY be evicted
- **AND** their archive copies SHALL NOT be deleted by time retention or the object reaper while the hold remains

#### Scenario: Hold before archive verification
- **GIVEN** a hold covers a block whose archive copy is not yet verified
- **WHEN** retention evaluates that block
- **THEN** its local copy SHALL be kept
- **AND** once the archive copy is verified the pin SHALL move to it

#### Scenario: Hold in local-only mode
- **WHEN** a hold covers local-only footage
- **THEN** its local copy SHALL NOT be evicted by the full policy or a local-only maximum age

#### Scenario: Held archive copy is lost
- **WHEN** the periodic re-check finds a held archive copy missing or changed
- **THEN** a critical alert SHALL name the hold
- **AND** if the local copy still exists the pin SHALL move back to it

#### Scenario: Hold races a deletion in progress
- **WHEN** a hold covers a block whose deletion intent already committed
- **THEN** the hold SHALL list that block as unavailable
- **AND** SHALL NOT claim to protect it

#### Scenario: Implicit release attempts
- **WHEN** a policy is disabled, storage is under pressure or a member disconnects
- **THEN** existing holds SHALL remain in force

### Requirement: Disk pressure never deletes unarchived footage
The system SHALL NOT delete pinned bytes as defined for the effective local window, or a held copy that is the hold's pinned copy, shorten archive retention, grow storage or change destinations to relieve NVR storage pressure; when nothing is evictable it SHALL let the NVR refuse admission and record a gap.

#### Scenario: Pressure with only pinned footage
- **WHEN** headroom cannot be restored without deleting pinned bytes
- **THEN** the NVR SHALL refuse admission
- **AND** recording SHALL stop with a gap and an alert naming each pinned cause that filled the volume with its bytes: upload backlog (pending or failed), archive deleting, archive missing, unreconciled, quarantined, held pins, local-only footage under `stop_when_full`, or the block cap

### Requirement: Safe and audited recording disposition
The system SHALL perform every deletion of recorded footage as a Core-issued operation bound to one catalog entry and an append-only disposition record, SHALL verify absence in the storage before marking a copy deleted, and SHALL treat reclaimed and deleted copy states as terminal.
No archive job, receipt import, registration, reconciliation or NVR recovery SHALL return a copy to a present state after deletion. The NVR SHALL persist a tombstone before unlinking a block and SHALL NOT delete blocks on its own.

#### Scenario: NVR crashes during reclaim
- **WHEN** the NVR restarts with a tombstoned, partially removed block
- **THEN** it SHALL finish removal and report the block as reclaimed, not incomplete

#### Scenario: Deleted block reappears
- **WHEN** an audit or lookup finds bytes for a copy in a terminal state
- **THEN** the system SHALL report the reappearance and SHALL NOT change the catalog back to present or re-delete automatically

#### Scenario: Retry after deletion
- **WHEN** an archive job is scheduled for an entry whose archive copy is deleting or deleted
- **THEN** the job SHALL do nothing

#### Scenario: Audit trail
- **WHEN** a copy is reclaimed or deleted
- **THEN** disposition records SHALL capture the reason, effective settings, hold check, execution and verified absence

### Requirement: Unified per-camera timeline playback
The system SHALL serve recorded footage for a camera by wall-clock range as an HLS playlist spanning catalog blocks, resolving each fragment to the local copy when present and otherwise to the verified archive copy, and SHALL verify every served fragment against its frozen descriptor digest so that either copy yields identical bytes.
Gaps, initialization changes, clock epoch changes and timestamp discontinuities SHALL be marked as discontinuities rather than filled with synthetic media. Local copies without local-copy registration for their storage lifetime SHALL be labelled provisional in the timeline and in each fragment response, and the label SHALL be removed once registration exists.

#### Scenario: Range spans local and archive copies
- **GIVEN** a requested range covers blocks whose local copies were reclaimed and blocks still stored locally
- **WHEN** an authorized user plays the range
- **THEN** reclaimed blocks SHALL be served from the archive and recent blocks from local storage in one playlist
- **AND** blocks that are local only after archive expiry or reaping SHALL be served from local storage and shown in the coverage as existing only on local storage
- **AND** each fragment response SHALL identify which copy served it

#### Scenario: Local copy fails during playback
- **WHEN** a local fragment read times out or the member is unreachable and the archive copy is verified
- **THEN** that fragment SHALL be served from the archive copy

#### Scenario: Local copy fails integrity
- **WHEN** local fragment bytes do not match the descriptor digest
- **THEN** those bytes SHALL NOT be served
- **AND** the local copy SHALL be marked missing and the archive copy SHALL serve only if verified

#### Scenario: Playlist across a gap
- **WHEN** a requested range contains a recorded gap
- **THEN** the playlist SHALL place a discontinuity at the gap
- **AND** the timeline SHALL show the gap with its reason

### Requirement: Bounded timeline reads
The system SHALL bound timeline playback by playlist window (at most 60 minutes, 2,048 segments and 256 KiB), per-session and per-node in-flight fragment reads, coverage resolution (at most 1,440 buckets and 31 days per query) and archive reader slots, and SHALL read archive fragments as ranged reads of the packed object without restoring a whole block.

#### Scenario: Seek cancels prefetch
- **WHEN** a viewer seeks to another position
- **THEN** obsolete fragment requests SHALL be cancelled and reading SHALL start at a fragment boundary

#### Scenario: Read capacity exhausted
- **WHEN** the in-flight read limit is reached
- **THEN** further fragment requests SHALL be refused with a retry hint rather than queued without bound

#### Scenario: Wide coverage request
- **WHEN** a client asks for coverage over more than the permitted span
- **THEN** the request SHALL be refused

### Requirement: Isolated archive reads with inventory credentials
The system SHALL read archive copies for playback through the isolated archive reader, supplying for each request the exact read plan and a reader-role credential resolved from the unified CNPG credential inventory, so archive playback works when the recording NVR member or its volume is unavailable.
The reader SHALL hold the credential only for that request and SHALL accept only the archive key family of the destination in the plan.

#### Scenario: NVR member lost
- **GIVEN** a block's local copy is unavailable because its NVR member is gone
- **WHEN** an authorized user plays it and its archive copy is verified
- **THEN** the footage SHALL play from the archive copy

#### Scenario: Credential handling
- **WHEN** the reader completes or fails a request
- **THEN** the credential SHALL NOT have been written, logged or returned

### Requirement: Authorized and audited recorded playback
The system SHALL require recording-read permission and fresh camera scope for every timeline, playlist, initialization and fragment request, repeated before bytes are released, and SHALL write an append-only access record for each playlist window issued and each hold operation.

#### Scenario: Permission revoked mid-playback
- **WHEN** a user's recording-read permission or camera scope is revoked during playback
- **THEN** later fragment requests SHALL be refused, including fragments listed in an already issued playlist

#### Scenario: Live-only user
- **WHEN** a user with live-view permission but without recording-read permission requests a timeline
- **THEN** the request SHALL be refused

### Requirement: Recording retention settings with defaults and bounds
The system SHALL store recording retention and policy choices as CNPG runtime settings editable from the settings UI with code defaults and bounds, and SHALL NOT require Helm values for them: high-water mark default 90% and low-water mark default 80% of the local budget, maximum local age default 24 hours (1 hour to 10 years) as a ceiling or unlimited, effective-window alert threshold default 1 hour or disabled, local-only full policy with no default selection (behaving as stop when full), local-only retention target default 7 days or none, local-only maximum age default unlimited, object retention default 30 days (1 to 3,650 days) or unlimited, optional per-policy object retention overrides, an object budget default unlimited with high-water default 90% and low-water default 80%, and an object capacity policy with no default selection (behaving as stop archiving).
Every optional limit SHALL be stored as an explicit mode with a value that is present and in bounds exactly when the mode requires it; an absent value SHALL NOT mean a default and no sentinel number SHALL mean unlimited.

#### Scenario: No settings row exists
- **WHEN** recording is installed and no settings have been saved
- **THEN** the code defaults SHALL apply and the view SHALL show them as defaults

#### Scenario: Invalid combination
- **WHEN** an operator sets a limited mode without a value, or a value out of bounds
- **THEN** the change SHALL be refused with the offending field named

#### Scenario: Archive retention shorter than the maximum local age
- **WHEN** an operator sets a limited object retention shorter than a limited maximum local age
- **THEN** the change SHALL be accepted
- **AND** the settings view SHALL warn that archive copies will expire while their local copies remain, leaving that footage with a single local copy

#### Scenario: Per-tier retention
- **WHEN** a camera has one policy for a high-bitrate profile with a short object retention override and another for a low-bitrate profile with a long override
- **THEN** each profile's archive copies SHALL expire by its own policy's retention

### Requirement: Stored-byte reduction without media recompression
The system SHALL NOT apply general-purpose compression to recorded media objects, and SHALL report each relay-eligible profile's observed bitrate and estimated bytes and blocks per day when an operator configures a recording policy.

#### Scenario: Operator chooses a profile
- **WHEN** an operator selects a stream profile for a recording policy
- **THEN** the view SHALL show estimated storage per day for each available profile and the projected effective local window for the member

### Requirement: Storage entitlement consumed at runtime
The system SHALL accept, on a hosted install, one storage entitlement document for this deployment over the private control-plane listener under a dedicated `entitlements` purpose token, with per-consumer allocation, overage policy and cap, capacity policy from plan terms, retention maximum and default, optional camera limit, an optional pending change with its effective time, and a strictly increasing revision; it SHALL store the applied document in CNPG and report the applied revision and digest. The system SHALL NOT model tenants, and no Helm value SHALL carry any entitlement field.
An install without the hosted runtime contract SHALL have no entitlement and no object capacity bound from it. A hosted install SHALL hold archive admission, keeping blocks pending and recording locally, until an entitlement has been applied, and SHALL treat a consumer missing from the document as disabled.

#### Scenario: Revision ordering
- **WHEN** the control plane pushes revision 7 after revision 7 has been applied with identical bytes
- **THEN** the push SHALL succeed without change
- **AND** a push of revision 6, a different document under revision 7, an unknown field or a wrong deployment reference SHALL be refused

#### Scenario: Self-hosted install
- **WHEN** an install has no hosted runtime contract
- **THEN** the entitlement routes SHALL have no effect on its settings and object storage SHALL be bounded only by the operator's own object budget

#### Scenario: Hosted install before the first entitlement
- **WHEN** a hosted deployment records footage before any entitlement has been applied
- **THEN** blocks SHALL stay pending for archive, recording SHALL continue locally, and the settings page SHALL show that it is waiting for a storage entitlement

### Requirement: Entitlement bounds recording settings
When an entitlement is applied the system SHALL use its recordings hard limit (allocation, or the overage cap when metered) as the read-only object budget, SHALL use the capacity policy from the plan terms recorded with the entitlement revision, SHALL bound archive retention and every per-camera override by the plan maximum with "limited by your plan" and without an unlimited choice when a maximum is set, and SHALL bound enabled continuous recording policies by the plan's camera limit.
A pending change SHALL be shown with its effective time and calculated consequence before it applies, and SHALL apply at its effective time; a later revision without it SHALL cancel it. A lowered plan maximum SHALL keep the stored retention and use the minimum as the effective value.

#### Scenario: Plan maximum below the configured retention
- **GIVEN** archive retention is configured to 400 days
- **WHEN** an entitlement sets a plan maximum of 365 days
- **THEN** the page SHALL show "configured 400 days, effective 365 days (plan maximum)"
- **AND** an attempt to save more than 365 days SHALL be refused with "limited by your plan"

#### Scenario: Pending allocation decrease
- **WHEN** an entitlement carries a pending lower allocation effective 24 hours later
- **THEN** the retention tab SHALL show the new allocation, its effective time and the projected retention and deletion it implies
- **AND** the reaper SHALL work against the old allocation until the effective time

#### Scenario: Camera limit reached
- **WHEN** an operator enables a continuous policy beyond the plan's camera limit
- **THEN** the policy SHALL be refused with "limited by your plan"

### Requirement: Shared calculated retention and usage report
The system SHALL compute object-tier retention with one common age cutoff T solving the sum over enabled policies of rate times the smaller of the policy's retention and T equal to the object low-water bytes less non-reapable bytes, report per-policy effective retention and binding bound, and satisfy the published test vectors so that the control plane's calculation produces identical results for identical inputs.
The system SHALL expose, under the `entitlements` purpose, a bounded per-day usage report for closed UTC days with retained, added and deleted-by-reason bytes, held and non-reapable bytes, object and request counts, archive read bytes, per-policy rates with opaque references and no camera names, and the projection, revisable only by a higher report revision.

#### Scenario: Two policies with different retention
- **GIVEN** policy A archives 50 GB per day with 7-day retention, policy B 20 GB per day with 60-day retention, and 1,000 GB is available
- **WHEN** retention is calculated
- **THEN** T SHALL be 32.5 days, A SHALL be time-bound at 7 days and B capacity-bound at 32.5 days

#### Scenario: Held bytes consume the available space
- **WHEN** non-reapable bytes reach the object low-water bytes
- **THEN** T SHALL be 0
- **AND** archive uploads SHALL continue, and SHALL pause for capacity only when non-reapable bytes reach the object high-water mark

#### Scenario: Usage report replay
- **WHEN** the control plane requests the same closed day twice
- **THEN** both responses SHALL carry the same report revision and figures

### Requirement: Cloud-delivered archive credentials in the credential inventory
The system SHALL accept Cloud-delivered writer, reader and retention credentials for the recordings bucket over a media-purpose route and SHALL store them only in the unified CNPG credential inventory, marked as managed by the control plane, with a credential generation; tenant operators SHALL see them read-only. No NVR-path component SHALL read bucket credentials from a Kubernetes Secret.
Rotation SHALL keep the previous generation usable until archive uploads and retention deletions that hold it have finished, and SHALL report the new generation's destination test result.

#### Scenario: Credential delivered
- **WHEN** the control plane delivers a writer credential with generation 3
- **THEN** a managed inventory row SHALL hold it, the writer slot SHALL point at it, and no response SHALL echo the secret

#### Scenario: Tenant operator edits a managed credential
- **WHEN** a tenant operator tries to edit, rotate, disable or delete a credential managed by the control plane
- **THEN** the change SHALL be refused and the inventory SHALL show it as managed by ServiceRadar Cloud

### Requirement: Storage lifecycle under suspension and termination
The system SHALL, under a durable recording stop set for suspension, stop new recording admission and new archive uploads while time retention, capacity reaping and holds continue under the applied policy, and SHALL, for termination, never delete held footage as part of deprovisioning and expose a bounded, paged manifest of held archive objects under the `entitlements` purpose.

#### Scenario: Suspended deployment
- **WHEN** a hosted deployment is suspended
- **THEN** recording and archive uploads SHALL stop, holds SHALL be kept, and retention SHALL keep running under the applied policy

#### Scenario: Termination with holds
- **WHEN** the control plane requests the held-object manifest during termination
- **THEN** the product SHALL return each held block's archive object keys, lengths and SHA-256 in bounded pages

