# Stream Doctor CI diagnostic evidence

## Contract and scope

`//build/media:stream_doctor_av_drift_test` exercises the supported Stream Doctor
RTMP-to-HLS audio/video drift diagnostic on RBE. FFmpeg generates an invented
320x180, 30-fps, 18-second H.264/AAC file. Stream Doctor adds visual frame markers
and audio tones, publishes RTMP, then decodes those markers from locally served
HLS. The control copies both tracks. The fault delays audio content by 500 ms
while copying video.

Both cases use the quality predicate `abs(drift_ms) < 50`. The control must pass;
the fault must fail and measure within 50 ms of the injected delay. Missing
measurements, fewer than ten recent samples, unexpected frame duration, invalid
JSON/numbers, failed media processes and deadlines fail independently. The metric
is content-relative synchronization, which supplements the existing independent
FFmpeg pixel and packet checks.

This is diagnostic-tool acceptance. It does not pass through ServiceRadar's
recording path or establish RTSP packet-loss/reconnect, browser playback, source
audio support, object integrity, GPU behavior or production timing limits.
Upstream's [current scope](https://github.com/membraneframework/stream-doctor/tree/v0.1.0)
is experimental RTMP-to-HLS drift; additional protocols and chaos metrics remain
planned. A product A/V path must exist before this diagnostic can test it.

## Declared dependencies

- Stream Doctor `0.1.0`, upstream commit
  `a38e67b27414eb50c8ff4c23836a6791658e53e5`, is a test-only Linux/x86-64 filegroup.
  [Official npm archive](https://registry.npmjs.org/@stream-doctor/linux-x64/-/linux-x64-0.1.0.tgz)
  integrity is pinned in `MODULE.bazel`:
  `sha512-1ycj8VtIxHscd6lFoKRppnHVQSpdsWq1gOzhU87UamWlX7MPbnd9B9j1lMapdjRVTAUJbN5D5psK+KcMH8x08A==`.
- FFmpeg `7.0.2` comes from the existing pinned
  `//third_party/membrane:media_test_tools`; Go uses the repository toolchain.
- No TypeScript SDK, Node, Python server, host FFmpeg, new Hex dependencies or
  product image changes are needed. The Go test drives the daemon's HTTP API.
- Upstream's [release recipe](https://github.com/membraneframework/stream-doctor/blob/v0.1.0/.github/workflows/release.yml)
  bundles OTP 28.3, Elixir 1.19.3 and native plugins on Ubuntu 22.04, with a glibc
  2.35 floor. It ran on the existing Ubuntu 24.04 RBE image without extra packages.
  This does not establish compatibility with another execution image or ARM64.
- Product pins remain unchanged. Upstream's source uses newer adaptive-stream,
  AAC FDK and Realtimer plugins than the application's shared Hex closure.
  A future source build needs its own dependency compatibility review.

The package is Apache-2.0; its native payload and the existing GPL FFmpeg tool
remain test inputs. Published npm provenance identifies the pinned upstream
commit; the provenance statement was inspected, not independently signature
verified. Repository fetching verifies the archive's pinned integrity.

## Bounds and cleanup

| Resource | Bound |
| --- | --- |
| Test work | 120-second context; one daemon, two sequential media cases |
| Startup / generation | 25 seconds / 20 seconds |
| Each case | 35 seconds; live-stream wait 10 seconds, measurement wait 20 seconds |
| Generated source | 18 seconds, 320x180 at 30 fps, 8 MiB file limit |
| HLS output | 19-second media cap, two-second segments |
| API | Two-second HTTP timeout, 32 KiB response limit, no redirects |
| Logs | Last 64 KiB per subprocess |
| Scratch | 1 GiB watchdog, sampled every 200 ms; not a filesystem quota |
| Runtime | Two BEAM schedulers; FFmpeg encoding uses one thread |
| Network | BuildBuddy `test.network=off`; only local HTTP and RTMP sockets |

All process working directories, temporary files and Burrito's extracted runtime
are under the test scratch directory. Children receive an explicit environment,
not deployment credentials. Cleanup stops the viewer and publisher before their
transport, then kills/reaps process groups with bounded waits and removes scratch.
The declared binary and finite media bound expected disk work; the watchdog
detects growth beyond that allowance, rather than claiming a hard disk quota.

## Verification on 2026-10-23

```text
bazel test --config=remote //build/media:stream_doctor_av_drift_test \
  --test_output=all --test_arg=-test.v --flaky_test_attempts=1
```

The [restored final RBE run](https://carverauto.buildbuddy.io/invocation/1278d8b2-a879-4a48-8f0f-85f473ec9a32)
passed in 20.8 seconds with external networking disabled:

| Case | Drift | Recent decoded samples | Quality predicate |
| --- | --- | --- | --- |
| Control | 3 ms | Ten samples at 3 ms | Pass |
| Injected 500 ms audio delay | 503 ms | Ten samples at 503 ms | Fail, as required |

Both reported 33 ms frame duration. Sampled scratch peaked at 504,631,068 bytes
(about 481 MiB), principally the bundled runtime. This is a dedicated media test,
not a small unit test or a product capacity benchmark.

The [negative-control mutation](https://carverauto.buildbuddy.io/invocation/40fcaaef-ed99-450a-8d7b-a76320185554)
replaced only `adelay=500|500` with `adelay=0|0`. The fault case then measured 2 ms
and failed specifically because delayed audio passed the quality predicate; the
control remained healthy. The mutation was restored byte-for-byte before the
final run. Initial standalone startup also passed on
[RBE](https://carverauto.buildbuddy.io/invocation/3e9ba398-f361-49bf-8a1e-60e59bdf41ff).

## Implementation choices

- **Tolerance: sound, medium confidence.** An encoder can add a small timing
  offset, so the control allows the upstream example's 50 ms tolerance; the
  measured offset is 3 ms. A 500 ms content delay must still fail the same
  predicate and match its known magnitude. The plan did not set an error budget.
  This threshold belongs to this diagnostic, not a production playback promise.
- **Finite sampling: sound, medium confidence.** The test waits for ten decoded
  samples from a finite 18-second source, rather than sleeping until the whole
  clip ends. This proves a real measurement promptly and caps a stalled run.
  It does not measure long-term clock drift; that needs a separately scoped test.
- **Scratch allowance: sound, medium confidence.** Starting the bundled daemon
  expands about 481 MiB before a useful measurement. The 1 GiB watchdog leaves
  room for its fixed runtime and short media while stopping unexpected growth.
  The plan required bounded work but supplied no size; this chosen allowance
  constrains CI cost and must be reconsidered with a dependency update.
- **One daemon, separate viewers: sound, high confidence.** Two cases share the
  expensive unpack/startup, but each creates a fresh viewer/metric collector and
  stops its publisher and transport before the next case. This keeps measured
  samples separate without expanding the runtime twice. Concurrency and restart
  behavior are outside this diagnostic's contract.

The exact test-only binary, Go driver and absence of product dependency changes
were approved before implementation. Shape/diff review kept this in one test
owner, added explicit external-network denial, and corrected teardown ordering.
The dedicated evidence document owns these pass choices; the integrating owner
updates the main implementation checklist and handoff.
