# Synthetic block grouping: logical bytes

Task 0.6 remains open. This experiment measures local logical content and encoded
descriptor sizes. It does not measure database, object-store or deployment costs.

## Input and independent check

The existing `PackagingTest` keeper repeats one complete synthetic H264 baseline
GOP (30 frames at 15 fps, 64 by 64 pixels) 32 times with increasing 90 kHz PTS/DTS.
The native production parser/muxer produces 32 independently decodable two-second
fragments: 960 frames and 64 seconds. UTC stays unknown. Repeating a complete GOP
keeps the input finite; it does not represent scene diversity or camera bitrate.

The test passes the same native fragments through production Spool in groups of
1, 8 and 32. Each block is sealed, recovered, read through its committed ranges,
and independently decoded by the pinned FFmpeg. The concatenated decoded frames
must match the original elementary-stream GOP decoded independently and repeated
32 times. Frame count, decoded-byte digest, fragment count and media-byte
conservation all gate the reported measurements. The existing random-access and
timing assertions remain in their original keeper.

Each group also goes through the pure receipt-free `RecordingDescriptor` encoder.
Its encoded size is separate from the spool directory's regular-file sizes;
the experiment neither writes descriptors to CNPG nor freezes a database block.
The measurement covers 37 blocks and 96 appends across the three groupings, with
an asserted eight-MiB ceiling on the common packed media. Decoders use one thread.

## Observed bytes

These are logical bytes for this fixed synthetic input, including every regular
file in each recovered spool directory. Decoder readback files live outside
those directories and are excluded. Descriptor sizes exclude upload receipts.

| Fragments per block | Blocks | Media | Init | Journal | Total spool | Total descriptors | Largest descriptor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 32 | 430144 | 21440 | 24058 | 475642 | 23422 | 745 |
| 8 | 4 | 430144 | 2680 | 9252 | 442076 | 8984 | 2257 |
| 32 | 1 | 430144 | 670 | 7714 | 438528 | 7482 | 7482 |

Grouping amortizes initialization and per-block metadata for this input; it does
not change the packed media. Every append still follows Spool's media sync then
journal sync contract. This experiment does not select a production block size.
The worker still stops at a finite block; the test does not implement rollover.

## Verification

Remote formatting used `bazel run -c opt --config=remote
//elixir/serviceradar_core_elx:format`. The final uncached run used:

```sh
bazel test -c opt --config=remote \
  //elixir/serviceradar_core_elx:recording_media_tests \
  //elixir/serviceradar_core_elx:quality_check \
  --nocache_test_results --test_output=all \
  --experimental_ui_max_stdouterr_bytes=10485760
```

The [final remote run](https://carverauto.buildbuddy.io/invocation/4a3336d1-0c98-4b2d-ab91-168b55c83c50)
passed all nine media tests and quality checks. A deliberate omitted append in
the last eight-fragment block made the
[negative control](https://carverauto.buildbuddy.io/invocation/8e64e28a-e38f-467b-a42d-a260964842f8)
fail at decoded-frame conservation: 5713920 bytes (930 frames) instead of 5898240
bytes (960 frames). The source was restored byte-for-byte before the final run.

Physical allocation, database row/index/TOAST/WAL sizes, cache behavior, provider
request counts and pricing, latency, sustained throughput and camera capacity
remain unmeasured. Object layout does not by itself determine billable requests:
retry, multipart, verification and reconciliation policies also matter. No live
media, database, credentials, provider or GPU operations were used. Historical
block authority and archive database validation are separate gates.
