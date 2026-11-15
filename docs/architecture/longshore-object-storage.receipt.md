# Longshore S3 object storage proposal and benchmark receipt

Upstream Longshore PR #28 (`8759583fd1888f292f290a5adbe883c8c6eb6aee`) is
pinned and integrated behind the opt-in `:longshore` archive adapter.
Baseline staging head: `0bd19190124931f8f46a285dcf5b17e89054ee37`.

## Artifacts

- [Complete OpenSpec review](longshore-object-storage.openspec.html)
- [Architecture diagram](longshore-object-storage.html)
- [Architecture source](longshore-object-storage.architecture.json)
- [OpenSpec design](../../openspec/changes/add-longshore-object-storage/design.md)
- [Benchmark report](../../openspec/changes/add-longshore-object-storage/benchmarks.md)

| Artifact | SHA-256 |
| --- | --- |
| Architecture source | `cdcf26e1b9baf38cd6e957a4d2e3c524cada5aa2474f9dc4f6e1d6c20c992b6f` |
| Architecture HTML | `0cc11e0072b7b0fed9ced0a9e1c96ec370af591fd44815d58552f1be343aa299` |
| OpenSpec HTML | `3f58a45952e0e4b760c42028cecfb961576a9c1907c506a930ed5e24b0a39790` |

## Validation

- Strict OpenSpec validation (`openspec validate add-longshore-object-storage --strict`) passed.
- Archify showcase delivery passed all 9 checks with zero errors and zero
  warnings, and verified all 15 repository source references.
- Automated browser containment and light/dark captures passed at 1440x900,
  1600x1000, 1920x1080 and 2048x1320; rendered screenshots were visually
  inspected.
- The portable OpenSpec review uses ServiceRadar Web-NG brand green and
  light/dark surface tokens, embeds the showcase diagram inline, and exported
  with zero unresolved local assets and zero notices. Desktop (1440x1100) and
  narrow-viewport (500x1100) captures were visually inspected.
- All modified Markdown files are ASCII-only and `git diff --check` passed.

## Remote Bazel and benchmark qualification

- All 17 remote unit, release-startup, contract, quality and synthetic
  benchmark targets passed on RBE:
  [Invocation e882b7d0-3f9f-48f8-9551-8572a2272212](https://carverauto.buildbuddy.io/invocation/e882b7d0-3f9f-48f8-9551-8572a2272212)
  (paired post-optimization NIF/native benchmark cached from
  [Invocation d6272abe-5b5a-46f4-8555-be9a7faebb88](https://carverauto.buildbuddy.io/invocation/d6272abe-5b5a-46f4-8555-be9a7faebb88),
  compared against pre-optimization baseline
  [Invocation b1937bb1-b46b-4584-83c3-74718e46e28c](https://carverauto.buildbuddy.io/invocation/b1937bb1-b46b-4584-83c3-74718e46e28c)).
- Live S3-compatible HTTPS WAN benchmarking, multipart NIF wiring, bounded
  selected-camera recording dogfood, and the 30-minute soak remain open pending
  cluster rollout and node locked-memory prerequisites.
