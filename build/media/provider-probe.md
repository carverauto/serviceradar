# Bounded object-storage provider probe

This opt-in diagnostic tests two newly created private S3 buckets with invented
bytes. It does not start with core-elx, adopt existing buckets, provision provider
resources, or qualify a deployment for Cloud use. `cloud_ready` stays false even
when every measured data-plane check passes.

The operator owns four temporary keys: one region-scoped bootstrap key kept
outside the cluster, a read/write key for bucket A, a read/write key for bucket B,
and a read-only key for bucket A. The Job receives only the three limited keys.
These are temporary ServiceRadar infrastructure credentials, not monitored-device
credentials. The production recorder credential contract remains unimplemented.

## Declared build and tests

```text
bazel test --config=remote //elixir/serviceradar_core_elx:provider_probe_test //build/media:provider_probe_release_startup_test //elixir/serviceradar_core_elx:quality_check --test_output=all
bazel build --config=remote //build/media:provider_probe_image
```

The image alias uses the existing core-elx Linux/amd64 image. Publish that image
through the existing image workflow and bind its exact digest in both templates.
There is no new SDK, package download, local build or credentials-bearing RBE
action. The protocol test uses a generated TLS certificate and a real HTTP/1.0
CONNECT proxy with no success headers. It exercises the actual production
`EgressClient.fetch_range/3` path. The separate release test unpacks the declared
release and invokes its entry point with no deployment credentials; invalid input
must produce one redacted JSON result and exit 1.

On Darwin/arm64, publish only this image with the declared launcher below. Keep
the RBE execution platform first. The two explicit runtime toolchains resolve
the existing pinned Darwin crane/jq binaries only for the launcher's Darwin
target platform; Linux image production retains its RBE toolchains. Registry
authentication and signing remain client operations outside build actions.

```text
bazel run --config=remote --stamp --extra_execution_platforms=//build/rbe:rbe_platform,//build/platforms:darwin_aarch64 --extra_toolchains=//build/media:provider_probe_crane_runtime,//build/media:provider_probe_jq_runtime //build/media:provider_probe_push
```

The launcher publishes only the stamped commit tag, never `latest` or a release
tag. Check that this tag does not already exist before publishing, then sign and
verify the new digest with the deployment's current signing identity. Do not
copy OCI layouts or patch generated launchers out of Bazel's output tree.

Req 0.7.5 signs requests without sending them. A private, bounded Mint 1.11.0
transport handles diagnostic S3 writes and metadata requests; production
`EgressClient` handles all range reads. No request follows redirects. This does
not change the general artifact-download transport.

## Operator preparation

Keep a private operator journal outside git. Record the fresh run ID, returned
bucket/key creation receipts, endpoint and region, exact Kubernetes resource
names/UIDs, image digest, and cleanup outcomes. Never record credential values in
that journal or print key-creation responses in a tool transcript. A lost creation
response is an unresolved operation, not permission to adopt an existing resource.

1. Generate a new 32-character lowercase hexadecimal run ID. Derive only
   `sr-vms-probe-<run_id>-a` and `sr-vms-probe-<run_id>-b`; refuse any collision.
   Keep the run isolated from other writers and policy changes for its lifetime.
2. Inspect `linode-cli object-storage endpoints --json` for the selected region's
   assigned endpoint, and verify proxy allowlisting and namespace egress before
   provisioning. Do not infer an endpoint from a region string. Record provider
   endpoint type privately; a passing E3 result is not evidence for another type.
3. Create one explicitly region-scoped bootstrap key with
   `linode-cli object-storage keys-create --label <fresh-label> --regions <region> --json`.
   Use a compact label such as `vms-<run_id>-boot`; keep purpose suffixes short.
   Capture its response directly into a private mode-0600 file. Never list or read
   existing access keys. Record only its returned key ID in the operator journal.
4. Supply that new key only to the immediate `linode-cli obj` child environment
   using `LINODE_CLI_OBJ_ACCESS_KEY` and `LINODE_CLI_OBJ_SECRET_KEY`. Disable SDK
   retries with `AWS_MAX_ATTEMPTS=1` and `AWS_RETRY_MODE=standard`. Use
   `linode-cli --no-defaults obj --key-cleanup-enabled no --cluster <assigned-cluster> mb <exact-new-bucket>`
   once per bucket, after an authenticated exact-bucket absence check. Do not use
   automatic key discovery, key cleanup, bucket enumeration, ACL mutation, or
   recursive removal. The installed CLI may lack the REST bucket-create action;
   `obj mb` is the explicit S3 creation boundary. Confirm private, unversioned
   creation before issuing limited keys.
5. Create the three limited keys using `object-storage keys-create --bucket_access`
   with one JSON entry containing `bucket_name`, `region`, and `permissions`
   (`read_write` or `read_only`). Do not grant the other bucket. Capture each
   creation response privately and record the returned key ID. Never put the
   bootstrap key into `input.json` or Kubernetes.

The operator supplies this input shape; all values below are invented:

```json
{
  "run_id": "0123456789abcdef0123456789abcdef",
  "region": "example-region",
  "endpoint": "https://objects.example.com",
  "writer_a": {"access_key_id": "invented-writer-a", "secret_access_key": "invented-secret-a"},
  "writer_b": {"access_key_id": "invented-writer-b", "secret_access_key": "invented-secret-b"},
  "reader_a": {"access_key_id": "invented-reader-a", "secret_access_key": "invented-reader-secret"}
}
```

## Encryption-policy diagnostic

Set `"suite": "encryption_policy"` in a fresh input to run the four encryption
denials separately. Omission or `"suite": "capabilities"` retains the capability
workflow below; other values are rejected. Each suite needs a new run, empty
unversioned buckets and an unused cleanup journal. Do not reuse a capability
run's buckets or journal for this suite.

Before running, the operator must have established ownership and installed the
intended policy on the new bucket A, preserving provider-managed limited-key
statements. This diagnostic does not create, replace or remove policy. Its
existing bucket-A writer must be allowed to read that policy; an unreadable
policy stops the suite before object writes, without requesting bootstrap keys
or broader credentials in the Job.

The bounded `GET ?policy` response must contain two explicit `Deny` statements
covering `s3:PutObject`, with principal `*` (or `{"AWS":"*"}`) and resource
`arn:aws:s3:::<bucket-a>/*` or `arn:aws:s3:::<bucket-a>/<run_id>/*`. Their conditions
must be exactly:

```json
[
  {"Null":{"s3:x-amz-server-side-encryption":"true"}},
  {"StringNotEquals":{"s3:x-amz-server-side-encryption":"AES256"}}
]
```

This deliberately recognizes only that policy shape. Extra conditions, negated
action/resource/principal fields, missing statements and other scopes are not
qualified. Other statements are preserved by the operator and are not a complete
ACL or policy audit by this diagnostic. The policy is read again after all four
checks; any byte change makes enforcement `not_confirmed`. Keep other writers,
credential rotations and policy changes excluded throughout the isolated run.

| Check | Rejected request |
| --- | --- |
| `put_missing_aes256_denied` | PutObject without the encryption header |
| `put_noncompliant_aes256_denied` | PutObject requesting `aws:kms` |
| `multipart_missing_aes256_denied` | CreateMultipartUpload without the header |
| `multipart_noncompliant_aes256_denied` | CreateMultipartUpload requesting `aws:kms` |

Each denial must be HTTP 403 with the exact `AccessDenied` error code. The same
identity must successfully write `AES256` before and after the denied attempt,
using the same key and operation, with per-object HEAD encryption attestation and
verified bytes. A signature error, unsupported-algorithm response, generic 403,
failed control or ambiguous initiation cannot pass. Multipart controls use one
64 KiB final part; encryption is requested at initiation, not on parts or
completion, following the [SSE-S3 request contract](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingServerSideEncryption.html).

The suite stops at the first unsuccessful check and leaves later checks
`not_tested`. Unexpectedly accepted writes retain their exact cleanup receipts;
an accepted multipart initiation with a usable upload ID is aborted and checked
absent. An initiation without a usable ID remains pending for operator
reconciliation. The existing 80 diagnostic requests, 30 cleanup requests and
64 MiB body limits apply unchanged. `policy_enforcement` summarizes the policy
reads and four denials, while `cloud_ready` remains false. This direct-provider
diagnostic cannot produce a mediated archive qualification report or enable
recording.

## Job and durable receipts

Prepare a private copy of [provider-probe-job.yaml](provider-probe-job.yaml) with
fresh run-specific names, the assigned namespace, approved proxy URL and built
image digest. Use `kubectl create`, not apply/adoption, for these new resources.
Create the input Secret from the private file using
`kubectl --context <context> -n <namespace> create secret generic <fresh-input-name> --from-file=input.json=<private-file>`.
This operation need not render Secret data in terminal output.

The Job has no service-account token, runs as a non-root user with a read-only
root filesystem, and has no bootstrap key. Its command is:

```text
/app/bin/serviceradar_core_elx eval ServiceRadarCoreElx.CameraRecording.ProviderProbe.main()
```

The mounted `sys.config` is empty, so the release does not load production
database/vault configuration or start application services. The PVC holds only
cleanup receipts and scratch, never object bodies or credential input. The
template requests a 10 MiB ext4 Longhorn volume. Longhorn v1.11.1 enforces a
10 MiB minimum and rounds to 2 MiB boundaries. Verify the selected class is ext4,
its replica allocation is affordable, and its reclaim policy is `Delete` before
creation. Keep the PVC until external cleanup is verified; it intentionally has
no Job owner reference or TTL. If provisioning fails, stop before creating the
Job and resolve the failure without switching to ephemeral receipt storage.

```text
kubectl --context <context> -n <namespace> create -f <private-job-manifest>
kubectl --context <context> -n <namespace> logs job/<fresh-job-name> --limit-bytes=65536
```

The JSON result and process exit code are both evidence. A Job that terminates
without a result, times out, or exits nonzero has not passed. Missing checks were
not executed. `not_confirmed`, `unsupported`, `failed`, and `incomplete` are not passes.

After the Job stops, use a private copy of
[provider-probe-recovery.yaml](provider-probe-recovery.yaml) with the same PVC and
image. This finite read-only Pod mounts no Secret and has no service-account
token. Its two finite containers print the journal and any interrupted atomic
replacement into separate log streams, each capped at 2 MiB. Retrieve with
`kubectl logs <fresh-recovery-pod> -c journal` and
`kubectl logs <fresh-recovery-pod> -c pending-journal`. Absence of
`cleanup.json.next` is normal and makes its reader exit nonzero; that Pod exit is
not a probe verdict. Capture both JSON documents, if present, privately and
reconcile their exact receipts. A missing primary journal or malformed document requires
operator reconciliation, never a claim of clean state. Delete the recovery Pod
after retrieval; no sleep container or retrieval deadline is required.

## Measured contract and bounds

| Check | Required observation |
| --- | --- |
| New empty buckets | Both bounded listings empty and versioning unconfigured |
| Private access | Anonymous object GET, bucket list and PUT denied; denied PUT leaves no object |
| Purpose separation | Reader can HEAD but cannot PUT/DELETE; A writer cannot GET/PUT in B; B writer can HEAD its control |
| Small object | 64 KiB invented bytes; full and partial 206 reads, exact interval/total, strong ETag and SHA-256 equality |
| Conditional read | Wrong `If-Match` receives 412 |
| Checksum rejection | Intentionally wrong signed `Content-MD5` receives `BadDigest`; no object remains |
| Multipart | 5 MiB first part plus 4 KiB tail; completion, full SHA-256 and a 32-byte cross-part range |
| Conditional PUT | Signed `If-None-Match: *` rejects different bytes at an existing key with `412 PreconditionFailed`; incumbent identity/hash unchanged; two concurrent writers to a fresh key produce exactly one success and one rejection |
| Conditional multipart completion | The same incumbent and two-writer checks on `CompleteMultipartUpload`; HTTP 200 with an embedded error never counts as completion |
| Abort | Each losing upload is aborted and its exact ID returns `NoSuchUpload`; the incumbent/winner still has its expected identity and bytes |
| Default SSE-S3 evidence | Both small and multipart HEAD responses identify `AES256`; missing evidence is `not_confirmed` |
| Explicit SSE-S3 | Signed `AES256` request on PUT and multipart initiation, followed by per-object HEAD attestation and verified bytes; reported separately for each operation |
| Cleanup | Exact owned uploads absent and exact owned objects absent after deletion; no unresolved version/initiation receipts |

The large multipart control remains independent of conditional writes and explicit
encryption. Additional multipart cases use one 64 KiB final part: they qualify the
commit/encryption operation, while the large control owns minimum-part and
cross-part evidence. Conditional checks do not use HEAD absence as their success
criterion. A `412` alone is insufficient: the incumbent must remain intact.
Two successes, ambiguous responses, transport failures and unexpected status codes
fail the affected check; a `409` does not trigger an automatic retry or a pass.
One writer pair is exercised per operation; this does not prove behavior across
all possible concurrent request orderings.
Later skipped checks remain `not_tested`. An explicit request with no HEAD
encryption attestation is `not_confirmed`, not proof of unsupported encryption.

There are at most 80 diagnostic requests plus 30 cleanup requests. Diagnostics
have 15 minutes, cleanup 3 minutes, and each HTTP request 30 seconds across connect,
upload and response. The Kubernetes Job has a 20-minute deadline and no retries.
The combined request/response body allowance is 64 MiB, with 2 MiB reserved for
cleanup. Each attempt reserves its full response ceiling even if interrupted;
successful requests refund unused capacity. Management bodies and response headers
are each capped at 16 KiB; the largest accepted range is 5 MiB plus 4 KiB. These
are application body limits, not a claim about exact TLS wire bytes. No media is
downloaded or captured. The Job is limited to 2 CPUs, 512 MiB RAM, and 128 MiB
ephemeral storage in addition to its receipt PVC.

The successful capability path is budgeted as follows; the TLS fixture checks the
actual request counts and keeps charged bodies below a conservative 20 MiB bound:

| Work | Requests |
| --- | ---: |
| Existing private/role/checksum/range and large multipart controls | 39 |
| Conditional PUT incumbent and two-writer checks | 8 |
| Conditional multipart incumbent, two-writer and loser-abort checks | 18 |
| Explicit SSE-S3 PUT and multipart | 10 |
| Diagnostic total | 75 |
| Cleanup of seven completed object keys | 21 |

Only two HTTP requests may be in flight. The caller reserves both requests and
their complete byte ceilings before starting either worker, collects both
outcomes, and alone updates the journal. Per-request deadlines include time spent
waiting to start. No worker owns a separate budget or cleanup receipt.

Failed denials retain their cleanup authority. Verified terminal denials followed
by HEAD absence remove only that exact object's receipt. An ignored bad checksum
can leave one additional object while the remaining checks continue: eight
objects plus at most two unresolved uploads require at most 28 cleanup requests.
Ambiguous initiation, timeout, version drift or exhausted cleanup bounds leave
receipts unresolved and cleanup incomplete; the operator must reconcile them.
The 2 MiB cleanup reserve exceeds 30 management-response ceilings. These limits
do not bound provider storage fees after an interrupted run; exact recovery still
belongs to the operator.

## Exact cleanup and interruption

Before first writing a new key, the probe checks that the exact key is absent and
persists cleanup authority. Conditional incumbent checks reuse only keys already
owned by this run. Upload initiation additionally records a pending receipt before
the request and the returned upload ID before sending parts. Journal replacement
uses an exclusive temporary file, file sync, rename and parent directory sync
before the next remote write. A crash can leave
both the older journal and `.next`; take their union for conservative recovery.
Never restart this run against an existing journal. Use a new run for another
diagnostic.

The Job removes only journaled object keys and upload IDs. It rechecks versioning
before each object deletion and refuses cleanup on versioning drift or unexpected
version receipts. It does not create delete markers or administer versioning to
make a result green. Pending initiation without a returned upload ID remains
incomplete. In that case the operator may reconcile a bounded upload listing for
that exact fresh bucket/run/key, retain the exact returned IDs, and abort only
those IDs. No recursive wildcard deletion is permitted.

The operator then verifies empty object, version and multipart listings for each
exact test bucket. Resolve only journaled or exactly reconciled run artifacts;
foreign content stops cleanup. Delete the two empty buckets using `obj rb` with
the same explicit bootstrap child environment and cleanup disabled, **without
`--recursive`**. Verify their absence. Revoke each of the four exact created key
IDs with `linode-cli object-storage keys-delete <key-id>`; never enumerate secrets
to recover an ID. Finally remove the exact Job/Pods, Secret, ConfigMap and PVC,
verify deletion and volume reclaim, and remove private credential files. Preserve
the redacted result and non-secret cleanup journal privately as operational
evidence; never commit live names, IDs, endpoints or output as fixtures.

## What a pass does not establish

Provider limited keys are broader than recorder-only authority: documented
permissions include operations such as object deletion and bucket creation/listing.
The diagnostic does not try to modify bucket policy, lifecycle or versioning, or
pretend these administration denials were measured. It always reports
`recorder_credentials: unsupported` and `object_lock: not_tested`.
`policy_enforcement` remains `not_tested` in the default capability suite; only the
separate encryption-policy suite measures the four denials above.
`atomic_no_overwrite` summarizes separately measured
`conditional_put` and `conditional_multipart` checks. `explicit_sse_s3` summarizes
`explicit_sse_s3_put` and `explicit_sse_s3_multipart`. A passing encryption check
attests the tested object; it does not establish a policy rejecting unencrypted
uploads. Missing HEAD evidence does not establish whether provider disks lack
encryption. An earlier HEAD 404 remains collision hygiene for the isolated run,
not an atomic archive-write guarantee.

The candidate conditional-write semantics come from the
[AWS conditional-write contract](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html).
They are not evidence that an Akamai endpoint supports those operations. Synthetic
TLS results qualify the diagnostic, not the provider. Conditional writes,
explicit SSE-S3 and the encryption-policy suite have not yet been exercised
against the real provider; the two
historical exercises below do not establish either capability.

Cloud provisioning, storage-broker credentials, object
lock/retention, in-flight capability revocation races, and provider
outage recovery require separate work. Default encryption is verified on newly
written objects because provider rollout and endpoint capabilities can differ.

Akamai documents a phased E2/E3 default SSE-S3 rollout from October 6 through
November 16, 2026. Objects uploaded before enablement are not retroactively
encrypted; its guidance requires checking the individual object's HEAD response.
An endpoint type or calendar date alone cannot establish object encryption.
See the [SSE-S3 guide](https://techdocs.akamai.com/cloud-computing/docs/default-encryption-at-rest-sse-s3)
and [rollout announcement](https://techdocs.akamai.com/cloud-computing/changelog/sep-28-2026-obj).

## Live exercises: storage evidence and remaining gaps

The initial authorized exercise verified private access, intended object-role
denials, signed checksum rejection, conditional reads, and bounded range/hash
checks using invented bytes. It did not complete the multipart test: the probe's
receipt parser rejected a legal unreserved tilde in an opaque upload ID. The
parser now admits that character within its existing length bound, and a wholly
invented receipt exercises completion, abort and cleanup through the TLS fixture.
Other unsupported receipt forms still fail closed and preserve pending authority.
This is a bounded diagnostic parser, not a general S3 XML implementation.

After that exercise was cleaned up and the fix was tested, a second authorized
exercise used fresh isolated resources. It passed the same object, access, role,
checksum and range checks, plus multipart completion, full hash and cross-part
range verification, separate multipart abort, and the probe's exact cleanup.

Neither the small-object nor multipart HEAD response in the second exercise
attested default SSE-S3; both results are `not_confirmed`, so the overall result
remains failed and Cloud readiness is unestablished. Explicit SSE-S3 requests and
atomic no-overwrite remain `not_tested`.

The first cleanup completed before investigating or changing the parser. The
operator reconciled the sole pending initiation to its exact test key and upload ID,
aborted it, and verified `NoSuchUpload`. The second exercise recovered an empty
cleanup journal with no pending initiation or version receipts. In each exercise,
both fresh buckets were independently verified empty of objects, versions, delete
markers and uploads, removed non-recursively, and verified absent. All four
created keys were revoked; their signed requests returned `InvalidAccessKeyId`
afterward. The Job and its Pod, credential Secret, runtime ConfigMap, recovery
Pod, PVC, PV and backing storage volume were removed and absence rechecked.
Credential files were then removed. Exact operational receipts remain private;
no live identifiers or response captures belong here.

Primary references:

- [Akamai access-key permissions](https://techdocs.akamai.com/cloud-computing/docs/manage-access-keys)
- [Access-key API](https://techdocs.akamai.com/linode-api/reference/post-object-storage-keys)
- [SSE-S3 rollout and evidence](https://techdocs.akamai.com/cloud-computing/docs/default-encryption-at-rest-sse-s3)
- [Provider limits](https://techdocs.akamai.com/cloud-computing/docs/object-storage-product-limits)
- [AWS SDK compatibility](https://techdocs.akamai.com/cloud-computing/docs/aws-cli-sdks-support-details)
- [Linode CLI 5.68.0 object-storage plugin](https://github.com/linode/linode-cli/blob/v5.68.0/linodecli/plugins/obj/__init__.py)
- [Longhorn 1.11.1 minimum size](https://github.com/longhorn/longhorn-manager/blob/v1.11.1/util/util.go)
- [Longhorn 1.11.1 CSI size enforcement](https://github.com/longhorn/longhorn-manager/blob/v1.11.1/csi/controller_server.go)
