# Recording metadata

`serviceradar_recording_metadata` owns the existing canonical v1 recording
`Descriptor`, archive `Manifest` and local publication intent
(`LocalPublicationIntent`) and acknowledgement (`LocalPublicationAcknowledgement`)
contracts under `ServiceRadarRecordingMetadata`.
Core and NVR consume the same validation, stable object keys and encoding. The
library uses Jason and OTP crypto; it starts no database, service or media pipeline.

Descriptors describe verified sealed blocks without storage receipts. Manifests
add validated object receipts. Local publication intents bind a descriptor to a
storage UUID and operation for Core reconciliation. Acknowledgements identify
`intent_accepted` and bind the operation UUID and digest of the complete intent;
Core emits them after committing acceptance. The codec checks correlation, while
the control caller owns response authentication. None of these documents
prove byte availability, physical durability, current writer authority or
playback access. Those checks remain with the caller. Existing descriptor, manifest and intent
v1 fields, bounds, bytes and identity-derived keys remain unchanged.

The standalone `unit_tests` target owns pure metadata validation and the pinned
v1 manifest digest. Core's native packaging tests own conversion from actual
media snapshots; NVR's shipped-release test owns restart descriptor generation
and independent byte/fragment verification. Core integration tests continue to
own frozen descriptors, fenced publication and archive receipts.

```sh
bazel test --config=remote //elixir/serviceradar_recording_metadata:unit_tests
```
