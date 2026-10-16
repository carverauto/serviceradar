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
Bandit transport deliver each 60,374-byte message. All column values and identity receipts
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

RBE invocation
[4351adc8-3276-4019-9f4f-3010c400b3d4](https://carverauto.buildbuddy.io/invocation/4351adc8-3276-4019-9f4f-3010c400b3d4):
the transport test passed in 25.0 seconds after the prefix-freshness count
byte. Runtime versions were OTP 28, Phoenix 1.8.15, Bandit 1.12.5 and Gun
2.6.0. Each fresh server VM used four schedulers; debug logging was disabled
in that VM. An earlier run,
[55358647-2884-44ac-8b58-e35c14d39148](https://carverauto.buildbuddy.io/invocation/55358647-2884-44ac-8b58-e35c14d39148),
measured the frame before that count byte.

CPU is total server-process user plus kernel CPU for the measured interval.
Roundtrip includes client decompression; throughput is aggregate deliveries per
second. RSS is the server snapshot after all clients completed warmup and
before measurement, in MiB.

| Rows | Clients | Compression | Server CPU ms | Roundtrip p95 ms | Frames/s | Connected RSS MiB |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| uniform | 1 | off | 10 | 0.318 | 2,565 | 119.6 |
| uniform | 1 | on | 40 | 0.997 | 987 | 115.3 |
| uniform | 10 | off | 70 | 1.139 | 12,388 | 123.2 |
| uniform | 10 | on | 180 | 1.829 | 6,641 | 121.5 |
| uniform | 100 | off | 380 | 6.102 | 25,565 | 140.0 |
| uniform | 100 | on | 2040 | 20.000 | 6,005 | 166.3 |
| mixed | 1 | off | 20 | 0.301 | 2,646 | 112.2 |
| mixed | 1 | on | 210 | 7.928 | 128 | 109.4 |
| mixed | 10 | off | 60 | 0.642 | 17,899 | 119.9 |
| mixed | 10 | on | 2120 | 21.891 | 568 | 119.1 |
| mixed | 100 | off | 450 | 6.278 | 25,624 | 141.4 |
| mixed | 100 | on | 22500 | 284.874 | 534 | 174.8 |

At 100 clients, including warmup, uncompressed binary payload totals
211,309,000 bytes. Compression reduces uniform payload to 2,884,900 bytes
(98.6% reduction) and mixed payload to 93,486,200 bytes (55.8% reduction).
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
