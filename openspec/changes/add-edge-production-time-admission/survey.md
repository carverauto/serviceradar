# Edge stranding survey (2026-11-15, staging e08e7e42a4)

Read-only survey of every durable edge store and every path that can leave
captured data on disk without a central terminal disposition. "Strand" means
the bytes stay local with no automatic path to a central receipt: delivered
and applied, audit, security quarantine or reject-audit. Evicting data with a
count is loss, not stranding, and is listed separately.

## Edge records

| Path | Can strand today | Why |
| --- | --- | --- |
| Pre-lane flat spool (`<edge-records>/lane.seg`, evidence, `data/`) after upgrade from 1.5.1 or earlier | Yes | The current agent never opens it. #6652 retires it only when it is provably empty. A committed tail cannot enter a lane, because `PrepareRecord` judges production authority and the fence at admission time, and fails a days-old record with `ErrAuthorityExpired` or `ErrFenceStale`. |
| Producer bounded in-memory queue before lane admission (`AppendPrepared` retry) | Yes (lost on restart) | `attributionRefusal` keeps authority refusals pending in memory. A record prepared before its grant lapsed is lost on restart, and admission refuses it once the grant lapses. It never reaches disk, so this is loss rather than stranding, but the same rule fixes it. |
| Lane generation, production grant expired, fence current | No | The sender requests a same-spool RENEWAL grant (`go/pkg/edge/sender/grants.go`), and core issues it while the assignment is active. |
| Lane generation, assignment deleted (fence missing at gateway) | Yes | `EdgeRecordAuthorization` withholds retryably forever unless a recovery ROLLOVER grant exists. Ordinary and renewal delivery stay withheld, which caps the lane. |
| Lane generation, assignment revoked or superseded (fence stale, no grant) | Conditional | Core issues no grant for a revoked assignment. The gateway rejects permanently (`fence_stale`), so the record leaves the lane, but it lands in the bounded local quarantine and is never applied, even when it was produced while its epoch was current. |
| Local rejection quarantine (`quarantine-<seq>-<eventid>.pb`, 1024 records / 4 MiB) | Yes (by design today) | It holds evidence only. There is no redrive, and the oldest entries are evicted. |
| Core EventWriter DLQ for `output_grant_not_current` | Yes | `OutputGrants.check_current` requires an active grant at the exact current epoch. A grant that moved on while the record was in flight dead-letters it, and a replay re-runs the same current check. |
| Gateway | No | It keeps no disk buffer. It publishes to JetStream or withholds, so the record stays in the agent spool. |
| Records failing structural or signature validation | Not data | A malformed record or one signed by an unknown key carries no authority. It is rejection evidence, not captured data. |

## Other edge queues

| Path | Can strand today | Why |
| --- | --- | --- |
| OTel add-on relay spool (`/var/lib/serviceradar/otel-spool`) | Conditional | A `spool_dir` change opens a fresh spool and abandons the old directory, and a backend switch to JetStream drops the spool handle. Unacknowledged frames stay on disk with no rescan. Grant, fence, restart and outage cases evict with a count instead (bounded by `max_bytes`). |
| Endpoint inventory pending upload | No | It is a latest-wins snapshot, rebuilt under the current grant when it drains. An exhausted upload is replaced by the next scan. |
| Bumblebee, k8s public endpoints, workload identity `latest.json` | No | These are latest-wins snapshots, re-read and re-signed when they drain. `runs/<id>.json` is written but never read, which is unbounded growth rather than stranding. |
| Sweep lease store, config caches, add-on checkpoints, updater staging | No | These hold control state, not captured data. |
| trapd, flowgger, log collector, BMP collector | No | They keep no disk buffer: data is lost on restart rather than stranded. That is out of scope here. |

## NVR/VMS media

Camera media never travels in edge record lanes. Each leg is its own HTTPS
channel, and seals and receipts are local JSON files plus CNPG rows.

| Path | Can strand today | Why |
| --- | --- | --- |
| NVR block spool (`$SERVICERADAR_NVR_SPOOL_ROOT/<block_id>/`) | Yes | `NVRArchive.archive_block/5` has no production caller, and no production code writes the first publication intent. The scheduler that delivers intents is off by default, and core never freezes NVR blocks. After any recovery-generation drift or a closed recovery gate, every archive, delivery and read is refused. Unsealed or uncertain blocks need manual `recover_block/2`. Nothing reclaims, so a full NVR stops recording while every block stays local. |
| Core-local persistent camera spool (core-elx PVC) | Yes | Only the manual one-shot `MediaUpload.upload_once/1` and `ArchivePublication.complete_once/1` drain it, and neither has a caller or a scheduler. A dispatch with an unknown outcome becomes `:reconciliation_required` and is never rearmed. A changed archive binding is a permanent `:archive_binding_conflict`. Pre-freeze blocks are never recovered. |
| Isolated storage-service scratch (`tmp/vms-media-staging`) | Conditional | It is a copy, so original media is not stranded. Leftover scratch after a crash halts every upload cluster-wide (`:storage_scratch_reconciliation_required`). |

Common root cause: data whose producing authority (grant window, fence epoch,
recovery generation, archive binding) has since changed is judged against the
current authority, and refused or withheld with no path to a central
disposition. The media path also lacks automatic drainers entirely.
