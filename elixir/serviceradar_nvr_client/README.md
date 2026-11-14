# NVR media client

`ServiceRadarNVRClient.send_recording/4` sends one finite, already-authorized
capture to the private NVR ingest endpoint. This library has no Core, database,
Membrane or NVR application dependency and starts no service. It is intended for
the recording coordinator or agent/gateway media bridge; it does not select a
camera, acquire assignment authority or activate recording by itself.

Load installed workload credentials with `ServiceRadarNVRClient.Config.load/2`.
The JSON file has exactly `host`, `port`, `ca_file`, `cert_file`, and `key_file`.
Certificate paths are absolute. The separate token file contains 32 through 512
printable ASCII bytes without a trailing newline. The client verifies the server
certificate and hostname against the installed CA. These are ServiceRadar
workload credentials, never camera credentials. Invalid configuration refuses
the operation; there is no URL, redirect, credential or replica fallback.

Pass the string-keyed header defined in [the ingest contract](../../docs/nvr-ingest.md)
and a lazy enumerable of `%{payload: annex_b_bytes, sequence: n, pts: pts, dts: dts}`.
Timestamp units are 90 kHz. The caller supplies a total timeout of 1 through
300000 milliseconds (default 30000). The enumerable executes in an isolated
process and must acquire its own resources there; a caller-owned socket or
mailbox is not a transferable enumerable. Coordinators must provide bounded
media admission and source/writer authority covering the operation, and keep
the source consumer independent of viewers.

Frames are pulled and sent one at a time. The client enforces the 1 MiB unit and
64 MiB application-body limits, reserves room for the explicit end marker, and
bounds response headers/body and the entire worker lifetime. Normal enumeration
completion sends the end marker and HTTP EOF. Source failure, invalid access-unit fields,
caller loss or expiry never intentionally requests sealing. A blocked source or
socket cannot outlive the operation deadline, including after caller loss.

A successful response must identify the requested storage lifetime and exactly
the consecutive block keys derived from the original recording identity. The
result is `{:ok, %{status: :sealed_local, storage_id: id, block_ids: ids}}`. It is
local sealing evidence, not catalog, playback, preservation or deletion
authority. A definite non-success HTTP response returns an `:ingest_status`
error. After transport, source or response-validation failure, `:outcome_unknown`
means partial or complete recordings may remain at the original NVR. The client
never retries media, increments the epoch or selects another endpoint. Discover
and reconcile retained blocks before authorizing any later operation.

The receiver's `//elixir/serviceradar_nvr:release_test` owns end-to-end transport
coverage. Its client cases run this library in an independent release VM,
exercise real mutual TLS, and independently decode NVR footage after restart.
An independent HTTP peer checks exact wire bytes, uncorrelated/malformed
receipts, server identity, no retries, aborted producers and deadline cleanup.
The test-only release artifact is a harness for this library, not a deployed
recorder or a new service.
