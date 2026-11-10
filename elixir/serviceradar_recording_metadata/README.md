# Recording metadata

`serviceradar_recording_metadata` owns the existing canonical v1 recording
`Descriptor` and archive `Manifest` contracts under `ServiceRadarRecordingMetadata`.
Core and NVR consume the same validation, stable object keys and encoding. The
library uses Jason and OTP crypto; it starts no database, service or media pipeline.

Descriptors describe verified sealed blocks without storage receipts. Manifests
add validated object receipts, but neither document proves byte availability,
physical durability, current writer authority or playback access. Those checks
remain with the caller. Wire v1 fields, bounds, bytes and identity-derived keys
are unchanged by the extraction from Core.

The standalone `unit_tests` target owns pure metadata validation and the pinned
v1 manifest digest. Core's native packaging tests own conversion from actual
media snapshots; NVR's shipped-release test owns restart descriptor generation
and independent byte/fragment verification. Core integration tests continue to
own frozen descriptors, fenced publication and archive receipts.

```sh
bazel test --config=remote //elixir/serviceradar_recording_metadata:unit_tests
```
