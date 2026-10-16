# Admitted-row overlay comparison

A synthetic experiment compared a browser Roaring runtime with direct typed
row overlays before choosing the latter. No deployment data was used. These
numbers are local Node measurements on a development Mac, not browser or GPU
acceptance results.

The final typed decoder, tested separately over 100 iterations with 64 tiles
of 128 rows, produced a 59,469-byte complete frame and 32,768 bytes of aligned
count buffers. Decoding and validating the whole frame measured 1.24 ms p95.
This is different work from the bitmap XOR/lookup probe below; neither timing
includes browser rendering or GPU upload.

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
