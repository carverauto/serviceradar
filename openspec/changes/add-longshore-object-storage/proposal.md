# Change: Use Longshore for object storage through Rustler

## Why

ServiceRadar needs a measured object-storage path for NVR recording and playback.
Longshore provides a bounded Rust S3 client, but its native benchmarks do not
establish performance or correctness inside BEAM or the recording pipeline.

## What Changes

- Introduce a reusable Elixir library with a thin Rustler boundary to the pinned
  Longshore client. Network work, buffer waits and shutdown run off BEAM's normal
  schedulers with bounded admission and explicit operation outcomes.
- Qualify Linux/container support and hermetic AWS-LC builds before deployment.
- Integrate through the existing archive storage authority after resolving the
  upstream API gaps in [design](design.md). Preserve immutable object identity,
  one-shot dispatch, integrity verification, credential isolation and retained
  local data.
- Prove synthetic round trips first, then bounded recording from the selected
  inventory camera into Akamai Linode Object Storage and authorized playback.
- Add reproducible native-versus-Rustler and end-to-end benchmarks, compare with
  Longshore's published methodology, and profile measured bottlenecks.

## Impact and boundaries

- New capability: object-storage-client.
- Expected code: a reusable Elixir/Rustler library, Cargo/Bazel dependencies and
  release packaging, the isolated camera storage adapter, and remote benchmark
  targets. Exact adapter activation depends on upstream contract qualification.
- [Recorder plane](../add-scalable-camera-recording-plane/proposal.md) continues
  to own source assignment, independent replicas, spooling and continuous capture.
  This change supports its tasks 3.4, 3.7, 5.2 and 5.5; it does not complete them.
- [VMS storage](../add-vms-storage-playback-engine/proposal.md) remains
  authoritative for catalog/playback and preservation.
- S3 stays optional. Local-only recording continues to use qualified storage
  replication supplied by the storage provider; this adds no media replication.
- The user authorized Rustler integration, live dogfooding and benchmarking.
  Physical worker-loss testing remains a separate operational action.

