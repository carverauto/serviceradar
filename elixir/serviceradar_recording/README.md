# Shared recording primitives

`serviceradar_recording` owns the bounded recording inbox, H264 access-unit to
CMAF packaging, storage-lifetime identity and append-only local spool. Core's
existing recording worker consumes these modules through `ServiceRadarRecording`.

This library has no core, database adapter, credential, cluster or relay-manager
dependency. Ecto supplies UUID casting only; it starts no repository.
Starting the application starts its library dependencies only; it opens no camera,
listener or spool and starts no recording worker. Ownership, authorization and
publication remain the consuming service's responsibility. Existing spool bytes,
journal records and storage markers are unchanged by the extraction.

The separate recorder service, enrollment, transport, process resource limits and
continuous policy reconciliation are still pending. Core's compatibility path
still requires explicit enablement through its existing configuration. This library does
not grant offline recording authority or prove physical source retirement.

## Validation

The spool recovery suite runs with only this library's dependency closure:

```sh
bazel test --config=remote //elixir/serviceradar_recording:unit_tests
```

Core's `recording_media_tests` and `recording_rtsp_tests` retain end-to-end media
coverage, including synthetic frame decoding, recovered byte ranges and the
recording descriptor boundary. Its browser fixture also uses the shared library.
Production and test compilation are available through `:erlang_app_prod` and
`:erlang_app`; neither target includes core's runtime.
