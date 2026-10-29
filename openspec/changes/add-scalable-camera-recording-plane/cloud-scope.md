# Cloud and customer-operated resource scope

The SaaS repo is [serviceradar-control](https://github.com/carverauto/serviceradar-control).
The product runtime stays single-deployment. Hosted account/environment inventory
is not a new runtime tenant column, shared BEAM cluster or access-control bypass.
A full self-hosted installation owns the equivalent local operator workflows and
must operate without the SaaS service.

| Owner | Required enhancement | Acceptance boundary |
| --- | --- | --- |
| Product | Deployment-scoped recorder pool enrollment, placement policy, capability reports, assignment epochs and storage lifetimes | Reject unknown/unqualified hosts and exhausted budgets; retain disconnected owners |
| Cloud #191 | Customer-operated pool registration alongside managed pools, desired/applied mode and residency intent | Enrollment does not grant camera, bucket or recording authority; no surprise provider allocation |
| Cloud #182 | Optional qualified S3 allocations, immutable ownership, private policies and per-purpose credential custody | Skip bucket/key provisioning for local-only mode; preserve all S3 qualification and denial checks when selected |
| Cloud #183 | Per-pool bitrate/storage/egress/analysis admission and preservation-aware lifecycle | Distinguish managed resources from customer-owned resources; never purge customer disks/buckets during generic teardown |
| Cloud #184 | Optional CPU/GPU analysis placement and independent quotas | GPU exhaustion cannot gate compatible recording; report measured capabilities |
| Cloud #190 | Restore planning and execution for installed controller/storage owners | Restore recorder inventory and pending operations with matching volume identities; no core Deployment assumption for recorder pools |
| Product and Cloud | Mode changes, offline grants, revocation and drained ownership handoff | Preserve historical placement/receipts and explicit data-movement authorization; no stale-owner takeover |
| Product and Cloud | Outbound-only remote viewing, shared live uplink ownership and independent gateway/media capacity | No customer ingress/VPN requirement; one source/uplink per camera/profile across viewers; media saturation preserves control |
| Product and Cloud | Playback admission, cache/read-ahead budgets and archive endpoint reachability | Private origins and interval authorization remain enforced; no full-recording disk restore prerequisite or automatic CDN allocation |

Existing issues:
[#182](https://github.com/carverauto/serviceradar-control/issues/182),
[#183](https://github.com/carverauto/serviceradar-control/issues/183),
[#184](https://github.com/carverauto/serviceradar-control/issues/184),
[#190](https://github.com/carverauto/serviceradar-control/issues/190),
[#191](https://github.com/carverauto/serviceradar-control/issues/191).

Issue #191 tracks the new customer-pool/mode work and proposed extensions to the
other issues; their existing acceptance remains mandatory. Filing it does not
mark any implementation complete.

Inventory must distinguish recorder ownership, storage ownership, archive policy,
customer versus managed hardware, capabilities, placement/failure domain,
requested/applied revision, actual admission and observed health. A row or desired
chart value is not readiness. Customer hosts receive scoped deployment identity;
camera secrets continue to use the product's unified encrypted credential model.
Infrastructure secret material stays out of inventory, chart values and queues.

Hosted readiness requires the product to attest compatible installed recording
and storage capabilities, applied policy, qualified resource capacity and current
operating authority. Meter admitted/recorded bytes, retained local/archive bytes,
object requests, WAN egress and analysis work separately; deduplicate retries.
Customer hardware should not be reported as a provisioned managed GPU/recorder.

Provisioning creates only resources selected by the mode, through resumable
ownership-aware operations. Suspend/disable stops new admission and reconciles
pending media; offline hosts and unknown stop outcomes remain unresolved.
Termination retains held footage, local volumes, unresolved uploads and inventory
until their own explicit disposition. De-enrollment revokes future authority but
is not proof that a disconnected process stopped or customer bytes were erased.

This file scopes future Cloud work, not a completed API or rollout. Each issue
needs its own control-plane OpenSpec, migration, negative authorization tests
and actual applied-state/lifecycle evidence before hosted enablement.
