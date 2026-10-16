# ServiceRadar Atlas synthetic binary-overlay GPU acceptance

This pass exercises the production WorldMapRenderer, Phoenix client, Arrow
reader, SRMO/SRTO decoders, Deck layers and WebGPU. The harness supplies invented
HTTP/WebSocket responses in the page. It is **not** a running Phoenix route,
database, authorization service or million-device backend acceptance run.

## Reproduce

Build the declared page with
`bazel run --config=remote //elixir/web-ng/assets:world_gpu_smoke`, serve the
assets directory on localhost, and open `world_gpu_smoke.html?bitmap=1`.
The harness contains 4096 invented grid devices and aggregate/leaf tile responses;
no deployment records or captures are fixtures. Use Zoom tiles, Toggle query,
Overview tiles and Pan tiles, then exercise reconnect, authority change, disable,
teardown and remount. The on-page counters expose explicit error and pending
states. A zero error counter is meaningful only after the requested transitions
have completed.

The automated owner tests run with
`bazel test --config=remote //elixir/web-ng/test/playwright:world_gpu_test`.
RBE uses SwiftShader; physical hardware timing below is separate.

## Defects found and repaired

The pinned Luma 9.4.2 compute pipelines shared a mutable module-level binding
dictionary, while each pipeline kept its own bind-group cache keys. A later
pipeline could change that dictionary without invalidating an earlier pipeline's
cached bindings. After label eviction, a fresh interleave command could therefore
submit a cached `rowIndexes` or `instanceIconDefs` buffer that had been destroyed.

A public compute regression creates two different pipelines, dispatches each,
retires the first input and rebinds the first pipeline to the second input.
Before the patch, the physical GPU reports a destroyed-buffer validation error.
With per-instance dictionaries it reports no error and writes the independently
expected integer 19. The maintained source/ESM/CJS dependency patch is declared
in Bun, pnpm and Bazel; package versions are unchanged. Existing queue-submission
lifetime guards remain necessary and are covered separately.

Deck finalization also left the separately created topology device and Luma's
per-device buffer pool alive. Topology now owns its adapter-created device,
submits pending work, finalizes Deck, drains the submitted queue and destroys that
device. Late creation after unmount is released too. It does not destroy a
supplied external device. The old teardown retained 20 buffers / 875,476 bytes in
this probe; the new teardown and remount teardown both reached zero tracked
buffers, bytes and devices.

The transport harness previously replaced `onAfterRender`, accidentally dropping
the production submit callback. It now chains the callback before measuring
frames. Errors remain visible even when subsequent telemetry updates status.

## Physical GPU observations

Chrome 155, macOS 26.6.2, Apple Metal 3, `fallback: false`; 1280 x 900 CSS pixels,
device pixel ratio 1. The final rebuilt page completed 16 overview/zoom/pan cycles,
reconnect, authority replacement and feature disable with no renderer or GPU
errors. It created a fresh device on remount, completed four more cycles and
released that device on teardown with no errors.

| Observation | Result |
| --- | ---: |
| Geometry requests / retained entries after cycling | 66 / 62 (64-entry cap) |
| Retained membership frame and aligned count columns | 47,192 B |
| Retained telemetry accounting charge | 263,920 B |
| Tracked whole-renderer GPU buffers at steady sample | 3,442,188 B |
| Peak tracked whole-renderer GPU buffers | 3,537,292 B |
| Membership-only replacement payload | 31,824 B |
| Phoenix ArrayBuffer slice during that replacement | 31,854 B |
| Geometry requests / Arrow bytes caused by that replacement | 0 / 0 |
| Three-second steady sample | 178 frame intervals |
| Frame interval p50 / p95 / p99 / maximum | 16.8 / 18.6 / 19.9 / 22.2 ms |

The 30-byte difference in the observed Phoenix slice is its binary event/topic
header. This measures that primitive, not every browser allocation or transport
copy. The decoder borrows u8 columns and SRTO row views, but aligns u32 counts in
a separate typed array. Arrow geometry still expands quantized positions and
bounded render attributes; GPU `writeBuffer` uploads copy their input. Animated
flow continues uploading while measurements run, so cumulative GPU upload bytes
are not attributed solely to one membership change. There is no browser Roaring
runtime, secondary WASM heap, bulk JSON ID list or base64 bitmap on this path.

Disabling binary support during an active filter released membership and overlay
retention to zero and showed an explicit unavailable state. Clearing the filter
restored base geometry. GPU counters include geometry, labels and flow buffers;
they exclude textures and the JavaScript heap. The fake backend's fixture cache
is also outside production renderer retention. These observations do not prove a
carrier-scale latency or total-memory guarantee.

## Executable verification

[BuildBuddy 02a26fc3](https://carverauto.buildbuddy.io/invocation/02a26fc3-239e-462a-aec7-391b82e4d098)
completed the production JS bundle, 626 browser unit tests and seven real WebGPU
browser tests. Those include the compute binding regression, binary overlay
refinement/reconnect/disable/teardown, and existing picking/detail/label-lifetime
contracts at both tested device pixel ratios. Full repository checks and actual
server-route acceptance remain the integrated workstream's responsibility.

## Filter builder component acceptance

The production map toolbar opens a device filter panel from the manifest's
supported fields and operators. It supports inventory VLAN, configured tag
values and names, IP/CIDR and separately discovered named Prefix Tags, composed
with AND, OR and unary EXCEPT. Prefix Tag discovery holds one request and one
50-label page, plus the selected label. Queries remain bounded control metadata;
membership and telemetry stay binary. The panel displays the exact accepted
SRMO total and clears it while membership is pending or unavailable.

On the same physical Chrome/WebGPU setup, actual UI clicks applied an inventory
VLAN and a named Prefix Tag, kept the query through zoom, and cleared it after
feature disable. No renderer errors occurred. That initial fixture returns
synthetic membership and does not validate backend predicate execution.

[BuildBuddy b715117c](https://carverauto.buildbuddy.io/invocation/b715117c-d797-41a5-9f66-cf9e8a0821c0)
passed the browser scene suite, seven WebGPU tests and the Phoenix miscellaneous
unit shard including the timestamp inventory. UI tests drive the real DOM
controls and transport boundary for grouping, exclusion, unavailable operators,
current/pending totals and stale catalog responses. A deliberate restoration of
the old same-generation manifest behavior failed the new cache readiness test;
the fix refreshes capabilities without refetching retained geometry.

## Atlas before/after capture

The `capture=1` harness mode mounts the same production renderer and filter
panel with 1024 invented devices: 16 clusters, each with four individual glyphs
and one 60-device aggregate. It omits harness diagnostic controls. The screenshot
is a real component capture, not the surrounding Phoenix page or a backend
integration test. The fixture supplies HTTP and WebSocket data; the production
Arrow, Phoenix client, binary decoders, layers and filter controls execute.

Actual UI clicks composed `(VLAN 20 OR VLAN 30) AND unavailable EXCEPT tag
maintenance=true`. An independent fixture test computes the expected membership
from the invented inventory, including each aggregate population. The accepted
SRMO total was 160: four individual glyphs, four aggregates containing 23 matches
each, and eight containing 8 each. Four zero-match aggregates and excluded
individuals are masked by the production policy; they do not display zero badges.
Filtered relations with partial aggregate membership are hidden, as the panel
explains. No exact filtered relation projection is implied by this capture.

Before and after have identical decoded geometry and camera target `[128,256,0]`
at zoom `0.75`. Chrome used a dark 1600 x 1000 CSS-pixel viewport at DPR 2. The
3200 x 2000 PNG captures were downsampled with `sips -z 1000 1600`; no compositing
or image edits were applied. The captures were handed to the website workstream:

| Image | Final dimensions | SHA-256 |
| --- | --- | --- |
| `atlas-filter-before.png` | 1600 x 1000 | `3267333588408cd87d0831a64219ffae18ce8491fcec00fa2b001a91714b015c` |
| `atlas-filter-after.png` | 1600 x 1000 | `a6529a08ea818820f1347845143b08c9b1721771ab2da11b09d504b15dfd5c24` |

This physical GPU capture reported no renderer errors. It exposed a subtle
visibility defect: a zero-radius stroked node could leave a subpixel dot.
Excluded, pending and stale nodes now use transparent fill, stroke and glow.
The existing layer regression failed before the repair in
[BuildBuddy 85bda303](https://carverauto.buildbuddy.io/invocation/85bda303-020c-47fd-917d-b8c6ee053f52).
The final 635-test scene suite and seven WebGPU tests passed in
[BuildBuddy 56545d47](https://carverauto.buildbuddy.io/invocation/56545d47-fc2d-4d3a-939f-a8143c12fe0a).

The same pass checks capability changes through the actual polling entry point
while the channel remains joined. The existing five-second poll refreshes the
small manifest even when geometry is unchanged, and retries temporarily absent
Prefix Tag sources with bounded backoff. Named label discovery retains one
50-label page; its 128 KiB response cap includes worst-case JSON escaping of
valid bounded labels. This is control metadata, not bulk membership JSON.
