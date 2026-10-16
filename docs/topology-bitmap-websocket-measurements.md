# Atlas negotiated WebSocket compression measurement

Production WebSocket compression remains disabled. The real transport reduces
bytes, but the mixed-row case consumes enough CPU to make enabling it globally
a poor default without an operational update-rate and CPU budget.

## Reproduce and scope

```sh
bazel test -c opt --config=remote //elixir/web-ng:bitmap_websocket_transport_test --test_output=all --flaky_test_attempts=1
```

This manual Linux acceptance target starts a test-only Phoenix endpoint on a
Bandit loopback listener. Gun clients perform actual HTTP upgrades, channel
joins, binary receives and normal code-1000 close handshakes. The production
SRMO encoder prepares 64 tiles of 128 rows; the actual Phoenix serializer and
Bandit transport deliver each 60,373-byte message. All column values and identity receipts
are invented; the query total equals the sum of the fixture's row counts. There are no new dependencies or production configuration hooks.

The paired matrix covers compression off/on, 1/10/100 concurrent clients,
uniform/mixed counts and availability, five warmups then 30 measured deliveries
per client. Every received Phoenix envelope and SRMO body is checked byte for
byte. A thirteenth case verifies that an enabled server falls back to plain
frames when the client offers no extension. All 445 connections and 15,575
deliveries complete, telemetry records no transport errors, and every client
and server peer terminates.

The actual negotiated response is
`permessage-deflate;client_max_window_bits=15`. It permits server and client
context takeover. The existing codec-only probe owns the no-context-takeover
comparison; this socket run does not claim to measure that variant.

## Results

Final RBE invocation
[55358647-2884-44ac-8b58-e35c14d39148](https://carverauto.buildbuddy.io/invocation/55358647-2884-44ac-8b58-e35c14d39148):
the transport test passed in 23.7 seconds, web-ng formatting/Credo passed, and
all four lane-routing contract tests passed. Runtime versions were OTP 28,
Phoenix 1.8.15, Bandit 1.12.5 and Gun 2.6.0. Each fresh server VM used four
schedulers; debug logging was disabled in that VM.

CPU is total server-process user plus kernel CPU for the measured interval.
Roundtrip includes client decompression; throughput is aggregate deliveries per
second. RSS is the server snapshot after all clients completed warmup and
before measurement, in MiB.

| Rows | Clients | Compression | Server CPU ms | Roundtrip p95 ms | Frames/s | Connected RSS MiB |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| uniform | 1 | off | 30 | 0.546 | 1,681 | 110.5 |
| uniform | 1 | on | 30 | 0.810 | 1,138 | 118.7 |
| uniform | 10 | off | 50 | 0.666 | 16,811 | 126.8 |
| uniform | 10 | on | 180 | 1.960 | 6,666 | 124.8 |
| uniform | 100 | off | 400 | 7.456 | 22,986 | 136.6 |
| uniform | 100 | on | 1870 | 23.415 | 6,529 | 167.8 |
| mixed | 1 | off | 30 | 0.452 | 2,232 | 118.6 |
| mixed | 1 | on | 220 | 8.590 | 126 | 120.7 |
| mixed | 10 | off | 40 | 0.533 | 19,160 | 116.6 |
| mixed | 10 | on | 2170 | 24.239 | 545 | 118.8 |
| mixed | 100 | off | 390 | 6.118 | 25,148 | 141.7 |
| mixed | 100 | on | 22490 | 255.980 | 535 | 174.4 |

At 100 clients, including warmup, uncompressed binary payload totals
211,305,500 bytes. Compression reduces uniform payload to 2,884,300 bytes
(98.6% reduction) and mixed payload to 93,483,200 bytes (55.8% reduction).
These are Bandit's actual post-deflate binary payload counters, excluding
WebSocket framing, control frames, TCP and TLS overhead.

## Accounting and limits

- Clients and server occupy separate BEAM VMs. Server CPU reads Linux
  `/proc/self/stat` user/system ticks and obtains the tick frequency from
  `AT_CLKTCK` in `/proc/self/auxv` (100 ticks/second here). Native zlib work and
  kernel work count; client CPU does not. The emitted Erlang runtime counter is
  separately named and is not substituted for process CPU.
- RSS and the kernel high-water counter come from `/proc/self/status`, including
  native allocations. These counters are approximate snapshots, and each case
  starts a fresh VM. Allocator/GC variation makes small RSS differences noisy.
  They are not an exact per-connection allocation estimate or a retention cap.
- The timed interval starts after all warmups and ends after client close.
  It includes Phoenix serialization, request processing, transport compression
  and shutdown; preparing the SRMO frames and establishing connections are
  outside it. The fixture retains 35 preencoded frames (about 2 MiB) to isolate
  transport cost. This is not the production one-unacknowledged-frame policy.
- This is a closed-loop saturation experiment over loopback, not a WAN,
  browser, TLS, idle-viewer or deployed-fleet measurement. No hard timing
  threshold is asserted on shared RBE hardware.
- The test-only channel serves prepared frames. Production authentication,
  query work, source publication, membership ACK/backpressure, reconnect and
  multi-replica behavior belong to hosted database/scale acceptance.
- Full repository `make test` was not repeated for this independent acceptance
  slice. No rollout, deployment or compression enablement occurred.

The kernel defines the process tick fields in
[proc_pid_stat(5)](https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html)
and supplies their frequency through
[getauxval(3)](https://man7.org/linux/man-pages/man3/getauxval.3.html).
