# Recovery verification evidence

This is checkpoint evidence, not a claim that every remaining contract is complete.
Guarded database execution and the final integrated gate are still required.


- Lane option regressions failed against the old opener in BuildBuddy
  `3e21d25e-426c-4e7a-a9b4-c3a9f0d9fa73`; the missing production filesystem probe
  failed in `056ff478-7dc5-4e52-986c-76c3ee29a10a`. Fixed spool/agent targets passed
  in `4a827ec1-317b-4cd2-9c31-fb35e3a6d265`.
- Integrated Go edge/agent plus Elixir edge contracts passed all 14 targets in
  `c23bdaf2-453c-4e5d-b15d-1aa6491bfadd`. Removing the registration partition guard
  made both markerless-slot omission and copy/loss-overlap tests fail in
  `3944d010-0c04-4e1f-8b0f-b30f8fce06bc`; the guard was restored afterward. The restored Elixir edge shard and all proto
  targets passed seven tests in `51652717-faaf-428d-98ef-2d17e6bcf9f7`.

- Binding constructors/grammar passed Go, Elixir edge and core quality in
  `85826a99-d281-4615-be10-c8b7b52bc42a`; 1,116 Elixir tests passed. Journal
  adjacency and complete-body mutations failed in `ac0a60bc` and `6d1794a6`;
  restored journal tests passed `0f260fae-8f12-4e7c-b013-d0194c62176e`. The clean
  journal ownership move passed spool in `d28e4687-c8b5-4a69-8bdc-04a94a236629`.
- Operation storage schema generated remotely through its committed writeback
  target. Database replay/conflict tests are pending guarded integration execution;
  unit-shard loading is not database evidence.
- Integrated Go edge/agent, Elixir edge and core quality passed all 15 targets in
  `9782af13-4dd7-475d-9364-b832fbcf3690`. Operation storage database tests were
  loaded but excluded by that unit shard; their persistence assertions remain pending.
- Gateway/core auth control and shared transaction checks passed all six targets
  in `211e2f6c-3044-4e1d-9b55-7a16c9773e52`. Removing installed scope membership
  made the foreign-scope query regression fail in both attempts of
  `f5a8af03-0097-4a96-8476-03a9804ee680`; exact restoration passed from the existing
  cache in `ba629dfb-7d94-480d-b690-be3f3ecce5dd`.
- Integrated sidecar/relocation storage, Go edge/agent, source interval schema,
  Elixir edge and core quality passed all 15 targets in
  `c1b5daae-5446-4460-881c-158d258bf0d7`. Guarded DB assertions for overlapping
  intervals and full uint64 coordinates remain pending. OpenSpec strict validation
  and inventory checks passed (66 checks, one skip).
- Consumer integration, Go completion verification, edge unit contracts and core
  quality passed four targets in `acccd5b8-e2a9-4e4e-9245-f614c978fb1c`.
  Removing the signed applied-state digest comparison failed both substituted
  prefix and root cases in `f2bfdeb2-814a-4b65-97be-8dfee471f06e`; the original
  source was restored byte-for-byte. Receipt/effects/prefix DB assertions remain
  pending guarded integration execution.
- Completion/source authorization, Go edge/agent and gateway/core unit and quality
  checks passed all 19 targets in `44194e5d-d3d8-4d7d-aefe-69aa594baeee`.
  Removing the four-page admission bound made the five-page rejection fail in
  `2414bed6-535a-4541-b355-8d3e1f555e33`; exact restoration passed from cache in
  `a6c82d52-3e32-4f3a-8d65-b62971dc7b02`. Inventory passed 66 checks with one skip.
  Completion immutability and issuance-order DB assertions remain pending guarded
  integration execution; unit compilation is not persistence evidence.
- Recovery catalog, production lane selection, EventWriter routing, runtime
  safety guards and Helm capacity passed all five targets in
  `c6044931-5810-4ce2-a6f4-ac74be9a432f`. Removing the registered control branch,
  catalog route selection and stream startup guard failed their intended
  regressions in `bd794461-46dc-4952-8b63-9b09bb0c1293`; originals were restored
  byte-for-byte. Inventory checks passed (66 checks, one skip). New boxed
  EventWriter receipt/rollback/deferred replay tests compiled but were excluded
  by the unit shard; guarded DB execution remains required.
- The actual sweep lease destruction/revocation test now checks historical mapping
  survival after assignment and execution-slot cascade deletion. The sweep shard
  passed in `3683aa5e-34d4-4ae2-8ac3-eda7eaf54738`; that run's quality attempt
  found formatting and its automatic retry was stopped. Formatting was corrected
  and quality passed in `edd7040c-3394-4428-9219-d9706dafbaa3`. The lifecycle DB
  assertions were excluded from the unit shard and remain pending guarded execution.

- Historical copy grants passed gateway/core unit and quality checks (five targets)
  in `37fd3c63-d895-408f-8cc8-3e85d10d2e94`. The preceding integrated run
  `635332eb-f54d-47ea-a203-dc21f32b12f1` passed 18 of 19 targets; its gateway
  complexity finding was fixed by separating envelope and item bounds. Allowing a
  compromised historical signing key made the typed-attribution regression fail
  in `8665c5a5-7cf7-4c6b-b50b-0225769bc932`; the verifier was restored exactly
  before the green run. Inventory passed 66 checks with one skip. Copy issuance
  database assertions remain pending guarded integration execution.

- Bounded runtime, historical copy grants, gateway boundaries, reserved creation,
  Go edge/agent and proto checks passed all 26 targets in
  `36c401d6-8c20-44c7-8194-3ea69570b24b` at integrated head `e619443c7d`.
- Same-reservation cleanup and typed producer-refusal checks were integrated as
  `2c111c22b3` and `b19c604964`. The follow-up
  `7b125216-1720-49eb-9260-65c91a95540b` passed 12 of 13 targets, including
  spool, agent, Cluster UI and WebNG quality. Core-Elx quality found one runtime
  configuration test exceeding its assertion limit; a focused recovery-configuration
  test is being separated before this checkpoint can be called fully green.

- Independent lane workers passed cmd agent, agent and sender targets in
  `66c5eced-b589-4842-9c57-aeb456c52412`; the peer's sequential-worker
  negative control was `091a58a3`.
- The configured-budget regressions failed before the fix in
  `9e2417c1-1ed4-4e37-a1f0-e9c47b5ec595`: an append was admitted after a
  16 MiB budget was refused, and the prior valid budget was skipped on correction.
  The shared admission gate now pauses until valid configuration is applied.
  All 14 Go edge/agent targets passed in `02eb0b49-6dbd-418c-86e1-5d9c837d7e0d`,
  including the source-bound destination intent integrated as `53d926021c`.
  Standalone `go vet ./go/pkg/edge/... ./go/pkg/agent/... ./go/cmd/agent/...`
  passed on Darwin/arm64 with Go 1.26.3 after the fix.

- Budget-pass review kept the shared gate as the single admission owner. Ripwire
  reported a normalized 22-token mutex pattern shared by a state getter and the
  new policy setter, plus an out-of-scope caller warning. The production budget
  owner calls the setter; these are separate contracts, so no artificial helper
  or suppression was added. OpenSpec strict validation passed.

- Exact-copy repair integrated as `3648c2b956` passed the spool target in
  `0aa270b2-7deb-4100-a088-ee272bda649d`. Review then found replay of a healthy
  closed final slot wrongly entered repair. The peer observed that regression
  fail in `787c9056`; correction `f3559eb0a7` passed the integrated spool suite
  in `75f8a41d-92ec-4fcc-b165-d3a57a20b491`.
- Immutable authority attempts integrated as `bc4820aa75` passed all 14 Go
  edge/agent targets in `bd39e3a8-ae01-44a6-b3aa-b73a8490002d`. The peer's
  mixed-attempt receipt negative control `2153afe2` failed reopened coverage
  when every receipt was incorrectly assigned to attempt zero.

## Reserved source lifecycle and gateway coverage integration

- Gateway coverage, provisional publisher deadline and MaxAge-zero recovery queue:
  peer `c604f69c-51a7-4ee5-b065-ff04ac32f1ba` passed eight targets; negative
  `c553e58d` caught late queued publication and the old expiring queue.
- Reserved active-source closure and storage-owned freeze builder: peer
  `503d3fe6` passed the full spool target. Negative `1250afe0` reproduced the old
  closed-source requirement; `63355a2a` caught resolved-prefix substitution for
  the physical reclaim base. The full-floor fixture uses 2,049 synthetic 32 KiB
  records across nine generations with actual injected append failure/corruption.
  Bounded rejected copies remain archived. A separate all-rejected case retains
  all evidence, completes, releases concurrency and capacity-refuses subsequent
  work; it does not claim perpetual progress with growing archives.
- Ordinary generation metadata admission: peer `4cdfc170` passed spool and both
  agent targets. Removing precharge failed `6b2b2535` because a new directory
  appeared at the reserved physical floor.
- Independent protocol review found no further copy-grant/principal/scope defect.
  It identified active source cancellation/join as a driver activation prerequisite.
  DB routing audit confirms real execution belongs to `BazelCI Core Integration`,
  async lane and the current serial-six lane, not unit compile/load results.

## Sender receipt and copy-authority barriers

- Integrated gateway coverage, reserved source freeze and ordinary metadata
  admission: `dc00ad00-e583-49a0-bee4-ee04681a3a35` passed all 22 affected Go/Elixir
  targets. Standalone Go vet passed for edge, agent package and agent command.
- Receipt barrier fail-before `00b6f314-a4c8-4514-abd1-dc3bd6a71f59` advanced the
  watermark without invoking the journal hook and ignored synthetic journal EIO.
  Fixed transport tests reopen the spool and require the original replay bytes on
  hook refusal; invalid acknowledgements never reach the hook.
- Required copy-grant fail-before `b7ec2815-e9da-402e-8260-43734e72733c` sent
  current-authority records without copy grants. Fixed cases cover current,
  unavailable, wrong-binding, expired, missing-tail and absent-issuer responses;
  a missing tail grant preserves accepted-prefix progress and later exact replay.
- `631ba264-ef7f-4e64-9f6c-856082218f2d` passed sender and both agent targets after
  both barriers; affected standalone Go vet passed. Quality review moved the
  receipt callback into the existing acknowledgement persistence owner, removing
  the added drain-loop complexity; final delta has no major existing-code finding.
  An independent storage review found only two stale grant comments, corrected.
- These sender tests establish transport ordering and replay, not actual recovery
  journal durability or allocator transfer. Production coordinator tests remain
  required for those contracts.

## Admission ownership cleanup

- Retired the unused Controller, sealed reclaim carrier and their test-only
  constructors; the live Gate consumes the filesystem allocator's usage. Removed
  861 net production lines and 1,042 test lines; existing Gate behavior is unchanged.
- Peer focused admission/spool/agent green `a0833e7d-ed4f-47e8-9d9b-872a90b00a27`.
  Retained Gate test negative `c844b4e6-e5fa-43b2-bf13-586d2bb21f15` admitted work
  at the high-water limit after deliberately disabling the pause rule. Exact
  restoration passed `db384846-fa61-4979-8e12-a1301c5eff3c`.
