# Native codec capability experiment

This test-only experiment measures the pinned media libraries and Linux Chromium.
It does not extend the production recorder, its baseline-only descriptor, or its
unknown UTC mapping. Task 0.4 remains incomplete.

## Measured scope

One shared fixture generates six seconds of independently invented 64x64 RGB
frames and mono tone markers. The pinned Membrane parsers and CMAF muxer produce
the initialization data and fragments. FFprobe checks track configuration,
packet counts and timing; FFmpeg independently decodes every video frame and
audio marker. Chromium consumes the same declared fixture and observes actual
decoded pixels and audio. Codec identifiers come from the emitted initialization
bytes, not a hard-coded browser capability list.

| Candidate | Native result | Chromium 156.0.8078.4 on Linux x86_64 |
| --- | --- | --- |
| H.264 Baseline + AAC-LC | All 90 video frames preserved; audio markers about 21.4 ms after their source positions | Playback, RGB frames and audio markers pass |
| Same media with audio PTS delayed 500 ms | Delay preserved; markers about 521.4 ms after their source positions | Playback preserves the injected delay |
| HEVC Main, 8-bit, no B-frames | All 90 frames preserved; expected PTS/DTS | `addSourceBuffer` returns `NotSupportedError` for `hvc1.1.6.L30.90` |

The native audio diagnostic allows 50 ms around the expected offset, including
encoder priming. Browser observation allows 150 ms for audio callback scheduling.
Neither tolerance is a production synchronization objective. Native decoding
does not establish browser HEVC support. A future browser that accepts HEVC must
decode the expected frames; append errors, decode errors and timeouts fail the
test rather than becoming an unsupported result.

## Bounds and cleanup

Inputs, packets, fragment count, bytes and encoder threads are finite. Each native
pipeline has a ten-second receive deadline. Both fixture targets set BuildBuddy's
`default-timeout` to 120 seconds with zero termination grace; this is an RBE action
bound, not a local execution guarantee. The native ExUnit test is capped at 60
seconds. Browser events and playback also have explicit deadlines. Temporary
files, pipelines, browser audio nodes, media URLs and the loopback server are
cleaned up.

Tool-output length checks run after capture. These fixtures therefore establish
a bounded known-input experiment, not safety against adversarial media. The
production recorder's admission and memory limits remain separate contracts.

## Evidence and execution

[Initial RBE validation](https://carverauto.buildbuddy.io/invocation/e9452002-62fe-42ec-8012-1e79734bf571)
passes seven targets: 210 core-elx cases, eight recording-media cases, three RTSP
cases, one native capability case, three existing browser cases, three capability
browser cases and quality. Five targets execute; recording-media and RTSP reuse
verified cached results. Every previous assertion remains.

The [negative control](https://carverauto.buildbuddy.io/invocation/2d7eeb34-f699-49ef-bcf1-969f31918a23)
deliberately removes initial container PTS from decoded-marker measurement. The
delayed clip then looks aligned, and the explicit delayed-alignment refutation
fails. The fixture is restored byte-for-byte before the final passing run.

Use the declared remote targets:

```sh
bazel test --config=remote \
  //elixir/serviceradar_core_elx:codec_capability_tests \
  //elixir/web-ng/test/playwright:camera_codec_capability_test
```

The shared fixture action is
`//elixir/serviceradar_core_elx:codec_capability_fixture`. This pass adds no
dependency, production export or runtime configuration. The full `make test`
sweep passes 437 targets, with 14 executed and two Swift platform skips, in
[619d7ac6](https://carverauto.buildbuddy.io/invocation/619d7ac6-665c-4e70-a66e-9636bc16b42f).
These earlier runs did not verify the claimed fixture action deadline: Bazel
9.2.0 filtered the original `execution_requirements` timeout key. The supported
replacement, actual 120.01-second timeout control and fresh nine-target positive
run are recorded in [validation](validation.md#fixture-action-deadline-correction).
Proxy validation remains a delivery gate.

## Still unproved

Production audio/multiple-track recording, RTCP clock provenance and uncertainty,
G.711 conversion, HEVC reordering/Main10, malformed or changing codec input,
Safari/hardware decoding, ARM64/GPU behavior, sustained throughput and capture
accuracy remain separate work. This experiment does not establish Whisper
transcription, Stream Doctor coverage, provider readiness, archive authorization
or deployment acceptance.
