# ServiceRadar Atlas admitted-row overlay comparison

A synthetic experiment compared a browser Roaring runtime with direct typed
row overlays before choosing the latter. No deployment data was used. These
numbers are local Node measurements on a development Mac, not browser or GPU
acceptance results.

An earlier typed decoder, tested separately over 100 iterations with 64 tiles
of 128 rows, produced a 59,469-byte complete frame and 32,768 bytes of aligned
count buffers. Decoding and validating the whole frame measured 1.24 ms p95.
This is different work from the bitmap XOR/lookup probe below; neither timing
includes browser rendering or GPU upload. That frame predates the current
four-byte exact-global-total field; its size is historical codec evidence.

The test used 8192 admitted rows. Dense IDs were 1..8192. Sparse IDs were
`(row + 1) * 524287`, spread across the unsigned 32-bit space. Baselines had
three populated sets (membership, unknown causal state, healthy availability)
and five empty sets. Half-change deltas contained two availability XOR sets.

| Payload, excluding envelope | Dense IDs | Sparse IDs |
| --- | ---: | ---: |
| Eight portable Roaring baseline sets | 24,664 B | 245,824 B |
| Two XOR sets changing half the rows | 16,416 B | 81,936 B |
| Complete typed row columns | 57,344 B | 57,344 B |

One hundred iterations of a native XOR plus 8192 membership lookups measured
15.29 ms p95 for dense IDs and 6.28 ms for sparse IDs in that run. These timings
are exploratory and do not establish a browser latency guarantee.

The published roaring-wasm 1.1.0 binary began with 20,840,448 bytes of linear
memory. A pinned source build using supported Emscripten settings reduced
initial memory to 4 MiB and enforced a 6 MiB maximum. Actual heap after the
experiment was 5,046,272 bytes. The generated runtime added 304,783 bytes
(76,493 bytes gzip) plus Emscripten and two upstream source dependencies.

Actual Rust portable fixtures interoperated with that source build, including
run containers and unsigned high IDs. A first scene-suite run passed 618 tests
and found two failures caused by a changed compiler i64 ABI default; a supported
compiler flag corrected the direct XOR smoke check. The discarded runtime did
not complete browser hardware acceptance and is not shipped.

The browser only renders admitted rows and does not need independent fleet set
algebra. Full typed overlays avoid the runtime/heap and have a predictable cost
regardless of dictionary sparsity. Roaring remains valuable server-side for
query intersections and exact aggregate counts. Geometry stays independently
cached; membership updates do not relayout or rebuild it.

## Binary telemetry replacement

The synthetic SRTO maximum-population tile (128 nodes, 512 edges) is 118,004
bytes. It preserves source progress, health counts, full flow coverage,
eligibility, nullable rates and microsecond observation intervals. The client
retains the buffer with lazy row access, with no persistent expanded edge array.
Its conservative retention charge is 191,732 bytes, including metadata and
CPU/GPU packet-attribute allowances.

A local Bun 1.3.9 warm run of 100 decode-and-validate iterations measured a p95
of 0.556 ms. This is a synthetic codec result, not physical-browser or GPU
acceptance. The browser and Elixir tests assert the same independent wire
digest; native producer tests separately verify row-order alignment.

## WebSocket compression probe

The production SRMO encoder and Phoenix binary serializer produced 60,405-byte
messages for 64 synthetic tiles of 128 rows. Bandit's negotiated
`permessage-deflate` implementation compressed 100 successive messages, changing
the sequence each time. An independent raw zlib inflater recovered every complete
Phoenix message byte for byte, with and without server context takeover.

| Synthetic row distribution | Context takeover | Compressed bytes, min-max | Deflate p95 |
| --- | --- | ---: | ---: |
| Uniform counts and states | No | 913-918 | 0.635 ms |
| Uniform counts and states | Yes | 844-915 | 0.817 ms |
| Mixed counts and availability | No | 26,933-26,936 | 5.278 ms |
| Mixed counts and availability | Yes | 26,723-26,933 | 6.412 ms |

Timing excludes the first ten samples and measures compression alone. This was
BuildBuddy invocation `9a498c5c-4e73-4125-8f0b-bc80174973c5`; the app-domain shard
passed 479 tests with zero failures (413 excluded), and formatting/Credo passed.
The experiment invokes the real extension negotiation and serializer, but does
not perform an HTTP upgrade, browser decompression, or concurrent socket load.

Compression substantially reduces these synthetic messages. Context takeover
adds little savings for the mixed distribution, which exceeds the deflate
history window. Keep compression disabled pending the concurrent transport
measurement: these results alone do not establish the CPU or connection-memory
cost of enabling it on the shared application socket. Full replacement frames
remain the protocol; unchanged-tile omission is a separate measured follow-up.
