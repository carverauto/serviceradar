# Source, consumer and assignment lifecycle

This is the implementation contract for task 1.2, not runtime readiness.
It refines the approved [design](design.md) without enabling recording. Wire
schemas, finite offline-grant construction, capacity/SLO values and the separate
recorder release retain their own open tasks.

## Existing boundaries to reuse

| Owner | Current responsibility | Limit of the existing implementation |
| --- | --- | --- |
| `RelaySessionManager` / `RelayOwnership` | Serialize one source/profile relay reservation before agent dispatch; reuse it for viewers; check consumers before idle close | A committed reservation is not proof that the external source started or stopped |
| `IngestOwnership` / `ConsumerLease` | Epoch-fenced current state and independently expiring viewer, recorder and analysis leases | Current expired-owner acquisition and five-second closing grace fence database mutations, not remote physical capture |
| Agent `cameraRelayManager` | Reserve a normalized source/profile through physical source Close, including plugin executor/socket cleanup | The reservation is local to one manager; it does not survive agent restart or fence another agent |
| `CameraRecording.Worker` / `Capture.once` | Attach a bounded recorder to an existing local Membrane pipeline and seal a finite block | No recording-policy scheduler, standalone pool or viewer-independent source startup |

The scalable path must extend these owners rather than add an independent
viewer-only source scheduler. Existing bounded capture remains available under
its present admission contract. Neither a new row nor a feature flag converts
that compatibility path into a qualified recorder pool.

## Three lifetimes, one physical source

The routing key is the deployment-local camera source UUID and stream profile
UUID. Inventory aliases are resolved before admission. Different profiles may
have separate sources; extra viewers of one profile may not. The connection's
deployment identity scopes the key; a caller-supplied tenant selector does not.

1. **Source ownership** binds that key to the authorized ingress agent, agent
   incarnation, monotonic source epoch and captured source session identity.
   It governs the physical camera connection and its fan-out root.
2. **Recording assignment** binds a recording consumer to a recorder/pool,
   recorder incarnation, storage lifetime, policy revision, recorder epoch and
   capacity reservation. The existing ingest and recorder epochs have distinct
   purposes; renewing a consumer must not silently advance either one.
3. **Cloud live uplink** is an independently admitted transport lifetime from
   that source's fan-out to one authenticated gateway/media destination. It is
   required by cloud recording or cloud viewers, not by local recording alone.
   All cloud viewers of the profile share it and their public Membrane fan-out.

A recording consumer is desired policy, not a browser session or an immortal
lease. A supervised reconciler renews its finite authority while policy,
assignment, storage and capacity remain valid. Viewer and analysis leases retain
independent identities and expiry. A heartbeat from one consumer cannot renew
another. An expired analysis job cannot pin ingest indefinitely.

| Admitted demand | Source | Recorder | Cloud live uplink |
| --- | --- | --- | --- |
| No consumers | Idle grace, then retire | None | Idle grace, then retire |
| Local recording only | One active source | Local assigned recorder | None |
| Local recording plus hosted viewers | Same source | Same recorder | One shared upload |
| Cloud recording, with or without viewers | One active source | Cloud assigned recorder | One shared upload |
| Viewer-only | One active source | None | One upload if viewers need the cloud path |

Authorized analysis may consume the same source under its own bounded lease.
It does not create another source, bypass primary admission, or require a cloud
upload when its processing is local. Its overload/drop policy is independent.

## Consumer operations and ordering

Persist desired demand, capacity reservation and the intended owner before
dispatching external work. Keep database transactions short: camera I/O,
process startup, worker drain and object requests happen outside the lock.
A durable operation record retains command identity and outcome so a controller
crash cannot turn an ambiguous dispatch into an unrelated new start.

Every mutating operation carries a version, operation ID, source/profile,
expected epoch/incarnation, target lifetime, policy revision and deadline.
Authentication binds the sender and allowed assignment. Replies bind the same
identity and state the observed stage; an accepted command is not a completed
activation or retirement. No arbitrary address/path can replace the admitted
target. Byte and concurrency limits apply before accepting a media RPC.

An identical operation retry returns or reconciles the original outcome. Reuse
of an operation ID with different content is a conflict. Expired or superseded
commands cannot recreate consumers, extend grants, move storage or close a new
session. Renewals are separate versioned operations, not deadline extensions
hidden in a retry. Reconnect reconciles the persisted operation and inventory
before issuing new work.

For a new recording policy, the reconciler reserves its consumer and capacity
before source activation, without inventing a viewer. It either joins the
current compatible source or activates the single reserved source. Recording
becomes active only after authenticated source/recorder attachment succeeds;
coverage becomes available only through the existing verified publication path.
Partial startup has a deadline and explicit cleanup/unresolved state.

For viewer attach, fresh authorization precedes a consumer lease and attachment
to the existing ingest. Concurrent first viewers and a recording-policy start
serialize on the same source/profile reservation, across coordinator replicas.
If source ownership is unresolved, attach waits within a deadline or fails; it
never opens an alternative source to improve apparent availability.

Detach releases only its named consumer. Last hosted viewer departure from a
locally recorded source may retire the cloud upload, but leaves local capture
running. Cloud recording itself retains the shared upload when no viewers
remain. Recorder stop/overload drains only the recorder branch when independent
viewers remain. Unrelated sources and viewer queues keep their own budgets.

When no consumers remain, reserve idle close under the source lock before
dispatch. An attach racing before that reservation keeps the source alive; one
arriving after it waits for retirement/reconciliation. Close always names the
captured source or uplink lifetime, never whatever a later lookup calls current.
An explicit authorized source-wide stop differs from recorder-only stop: it
prevents new attaches and drains all consumers of that exact source epoch.

## Assignment transitions and required evidence

States below are protocol states, not a declaration that the current Ash
resources already implement them. Source and recording-assignment state must be
reported separately from archive/index availability.

| Transition | Required evidence before advancing | Failure or unknown outcome |
| --- | --- | --- |
| Unassigned -> reserved | Current policy and capability checks; exclusive source reservation; recorder/storage identity and multidimensional capacity reservation | No start; release only reservations proven unused |
| Reserved -> activating | Persisted operation and authenticated target acknowledgement for the exact epoch/incarnation | Reconcile the same operation; no parallel replacement |
| Activating -> active | Source opened once; intended recorder attached to that ingest; transport and storage identities match | Drain known partial work; retain ambiguous ownership and report unavailable coverage |
| Active -> draining | Persisted stop/handoff intent fences new recording admissions; exact old worker/source identities captured | Existing authorized work follows its finite budget; no inferred completion |
| Draining -> retired | Recorder end ordered after accepted bytes, sealed or explicitly incomplete journal inventory persisted, and affected physical source/uplink executors retired or effectively fenced | Preserve media; enter unresolved if proof is missing |
| Retired -> replacement active | Retirement/fence evidence committed; old pending work has a durable recovery owner; replacement capacity and a new epoch admitted | Recover the persisted transition; do not reactivate the old epoch |
| Any dispatched state -> unresolved | Loss of a trustworthy outcome, participant, storage identity or validity determination | Block conflicting capture/writes; reconcile without deleting history |
| Unresolved -> retired or active | Authenticated reconciliation proves the old outcome and authority, or an independently qualified fence excludes the old owner | Remain unresolved; a timeout alone does not select an outcome |

For the initial full source/recorder handoff, reserve replacement capacity,
drain the old recording, preserve its journal/outbox inventory, confirm physical
source and affected uplink retirement, commit the old fence, then activate the
new epoch. Existing viewers may need a bounded reconnect; record the observed
gap. Keeping a source alive across recorder reassignment is a later optimization
requiring its own atomic routing/capacity proof, not permission for two writers.

Recorder-only stop leaves the shared source alive if another consumer needs it.
Full assignment handoff must account for those consumers explicitly; it cannot
interpret their continued source use as a successful source retirement.
Unexpired viewer authorization can be revalidated for the new epoch, but old
consumer handles are never transferred as authority.

Retirement proof is authenticated and bound to the operation, source/profile,
old epoch, process incarnation and captured session. It establishes executor
and socket closure, not merely receipt of Stop, a closed gateway stream, an
empty viewer count or an expired CNPG row. Writer retirement separately requires
exclusive-volume fencing and the retained journal inventory. Source closure is
not proof that a storage writer has stopped, or the reverse.

A qualified source-side fence or conservative expiry of an enforceable finite
offline grant may exclude an unreachable old owner. Until task 1.3 defines and
qualifies that mechanism, neither wall-clock passage nor a database lease is
accepted as such proof. Operator reconciliation must record verifiable fencing
evidence; an override cannot silently mark uncertain media or ownership safe.

## Crash and partition matrix

| Boundary | Recovery obligation |
| --- | --- |
| Reservation committed, command not sent | Reconcile persisted operation, then dispatch that operation if still authorized; no second reservation |
| Start sent, reply lost | Ask the authenticated participant for the same operation/incarnation; do not resend under a new identity or assume nothing opened |
| Source opened, recorder attach failed | Account for every partial source/uplink; retain other admitted consumers, retire unused resources with proof |
| Coordinator crashes while active | Recover demand and observations; do not synthesize a new owner from empty process memory |
| Agent or recorder reboots | New incarnation cannot inherit old authority from a PID, marker or catalog row; prove retirement/exclusivity and reconcile old media first |
| WAN/control connection lost | Local recording obeys its finite offline grant; hosted viewing reports loss. Reachable S3 may drain under existing bounded authority |
| S3 unreachable, control healthy | Continue only within the declared filesystem outage budget; preserve pending bytes at pressure limits; do not move the source to hide backlog |
| Stop/drain sent, acknowledgement lost | Keep the captured lifetime unresolved; repeat/reconcile the same operation, never close a later session |
| Recorder sealed, retirement not committed | Recover and verify sealed inventory; it remains tied to its original storage lifetime and epoch |
| Old owner retired, new owner not active | Preserve old outbox responsibility; retry new activation only under its admitted epoch; expose the uncovered interval |
| Old command/heartbeat arrives after replacement | Reject stale current-owner mutations; historical sealed work uses the separate provenance-checked reconciliation path |
| Volume missing or identity changed | Stop affected writer admission and preserve index/history; no startup adoption, recursive repair or automatic destructive cleanup |
| Viewer departs during recorder stop/handoff | Resolve both named consumers under the same source reservation; neither event proves physical retirement |

## Implementation order and acceptance

1. Implement persisted operation identity and incarnation-aware reconciliation
   with real command/acknowledgement boundaries; preserve all current lease and
   publication assertions. Keep the new pool path disabled.
2. Package the recording primitives as a separate service and qualify source,
   writer and transport retirement there. Do not expand the one-shot core API
   into a production continuous recorder as an interim shortcut.
3. Add one qualified pool and policy reconciler that starts with zero viewers;
   prove shared source and uplink counts under concurrent viewer activity.
4. Exercise every transition/crash boundary above, then offline grants and all
   storage modes under their own qualification tasks. Enable a bounded policy
   only after the relevant runtime and deployment gates.

Acceptance counts actual camera connections, agent executors and live upload
RPCs, not only rows. It must fail if two source/profile owners overlap, an idle
timer ends authorized recording, stale detach closes a replacement, a lost
reply opens a duplicate, optional analysis blocks capture, or last-viewer exit
retains an unnecessary local-recording WAN uplink. It also checks committed
journal inventories, explicit gaps and preserved historical identities.

These are required future tests, not claims that they ran in this docs change.
Task 1.2 is specified here; tasks 1.3, 1.7, 2.1-2.5 and the capacity/rollout gates
remain open. No source, bucket, volume or recorder is provisioned by this PR.
