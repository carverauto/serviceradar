# RTCP clock-evidence experiment

This test-only experiment measures `PacketNTP` in pinned gortsplib v5.6.6 over
synthetic TCP loopback. A sender report supplies a mapping; it does not establish
physical capture accuracy or trusted UTC. Production relative PTS/DTS and unknown
UTC remain unchanged. Task 0.4 is still incomplete.

## Observed behavior

Two fresh client/stream epochs reuse the same URL and RTP values. Each sends four
RTP packets and two explicitly invented sender reports. Expected calendar times
are specified independently of the wire NTP constants and the library's encoder.
The test waits for each actual RTCP callback before sending dependent RTP, then
calls `PacketNTP` from the actual RTP callback.

| Case | Observed result |
| --- | --- |
| RTP before any sender report | No mapping |
| Known report and subsequent 90 kHz ticks | Exact expected +50 ms mapping |
| RTP timestamp wraps through zero | Exact expected +200 ms mapping |
| Fresh client/source epoch | Starts unmapped; previous mapping is not inherited |
| Contradictory report advances the anchor by 30 seconds | Mapping remains valid and the next observation jumps 29.85 seconds |

The contradictory-report result matches the
[pinned receiver implementation](https://github.com/bluenviron/gortsplib/blob/v5.6.6/pkg/rtpreceiver/receiver.go):
the latest matching report replaces the mapping without a clock-plausibility
decision. The experiment records that limitation instead of treating
`mapped=true` as a capture-time guarantee. Report authentication, freshness, skew,
discontinuity policy and uncertainty growth need an explicit product contract.

## Bounds and preservation

Observation channels permit one outstanding packet/report and fail on overflow.
Each epoch has a five-second deadline, network operations have two-second
timeouts, and the Go test has a twenty-second deadline. Clients, streams, server
and listener close on exit. The invented H.264 payload identifies a clock track;
it is not used to claim video decoding.

The existing synthetic RTSP harness is reused. Its automatic sender reports stay
enabled for the recording tests, and every capture assertion remains. Only the
clock diagnostic disables automatic reports. The already-pinned `pion/rtcp`
repository is exposed for direct test imports; versions and locks are unchanged.

## Evidence and execution

[Final uncached RBE validation](https://carverauto.buildbuddy.io/invocation/33a0aa9a-0ca0-4074-b6ab-2c79c3475e2a)
executes and passes the clock target, both epoch subtests and all three existing
RTSP recording cases. The
[negative control](https://carverauto.buildbuddy.io/invocation/c6b3be5a-fe72-4e27-be07-3b9db4c63011)
shifts the transmitted RTP anchor by 90,000 ticks and fails the expected-time
assertion by exactly one second in both epochs. The source is restored before
the final passing run.

```sh
bazel test --config=remote \
  //go/pkg/agent:camera_rtcp_clock_test \
  //elixir/serviceradar_core_elx:recording_rtsp_tests
```

Compilation and tests ran on RBE. Go formatting ran locally, a deviation from
this session's remote-format workflow; it is not claimed as remote validation.
The 438-target `make test` result in
[9f994c74](https://carverauto.buildbuddy.io/invocation/9f994c74-4a00-406f-af4a-59d1b819d6b7)
predates the logical-byte experiment and archive reconciliation. Later sweeps
and the fixture deadline repair are in [the validation ledger](validation.md).

## Still unproved

This establishes neither physical clock accuracy nor production timestamp
transport. UDP loss/reordering, long-gap timestamp ambiguity, gradual drift,
sender authentication and camera clock quality remain unmeasured. A fresh client
in this harness does not prove full authenticated agent/gateway/core recovery.
