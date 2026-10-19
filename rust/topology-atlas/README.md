# Canonical aggregate membership

The immutable world owns positions, UID lookup and aggregate ranges.
`CanonicalOrdinals` pairs that world generation with a 16-byte dictionary epoch
using one u32 per position; it retains no second UID map or world reference.
Inventory remains the authority for unique, durable, nonzero ordinals.

Seed from dictionary keyset pages of at most 500 `{uid, ordinal}` pairs. UIDs
outside this world are ignored, so a global scan can seed any world. Replaying
a page is harmless; a conflicting reassignment fails the entire page. Seal
only after the owner completes the scan for its accepted generation. Unmapped
positions stay zero because provisional or noncanonical geometry is legitimate.
Sealed mappings are immutable, and stale world generations fail explicitly.

Bounded device lookup returns ordinals in input order, including zero for
unmapped positions. Native aggregate traversal excludes promoted devices and
exports portable Roaring membership directly, without a BEAM list or JSON
conversion. This traversal is O(member count), with a maximum one-second
deadline and an 8 MiB portable output limit. `aggregate_ordinals/5` takes the
caller's remaining whole-view byte budget before the timeout. It checks this
limit during traversal and before allocating serialized bytes, so an over-budget
view cannot first materialize another full 8 MiB payload. The mapping is capped
at 32 MiB. The native boundary holds a two-slot allocation permit for each
mapping's full lifetime, including retained query receipts and asynchronous
reclamation; a third mapping returns `busy` before allocating. It also admits
two aggregate reads, each with bounded bitmap/output
scratch. The owner includes retained mapping bytes in its replica memory
budget and validates the mapping epoch before querying a bitmap resource.
One copy creates the BEAM output binary from the serialized native buffer.

Use that membership with the server bitmap index for exact query intersections
or typed admitted-row overlays. It is not a browser membership representation.
Filtered detail pagination and bundle membership need their own explicit native
contracts; filtering the first unfiltered detail page cannot produce exact
pages or counts.

`ordinals_test` compares the portable sets with the existing detail iterator,
including high unsigned ordinals, unmapped geometry, promotion and generation
fences. `ordinal_scale_benchmark` declares 100,000 invented infrastructure
devices plus 1,000,000 endpoints in one aggregate, with compact and sparse
ordinals. It reports retained mapping bytes, portable bytes and p50/p95/p99
for native traversal/serialization over 100 samples after ten warmups.
The same declared scale target checks a second invented population of 2,097,664
members spread over 512 minimally dense containers. Its portable membership fits
the output/scratch limits. This protects against roaring 0.11.4's bit-capacity
statistic being mistaken for allocated bitset bytes, falsely refusing an export.
The packaged BEAM API test separately checks mapping admission, sealed-resource
retention and capacity recovery after an owning process exits.

[BuildBuddy cbffea9c](https://carverauto.buildbuddy.io/invocation/cbffea9c-d6e3-481f-9a27-a0d999c6c2f7)
measured compact/sparse aggregate traversal p95 of 15.56/33.98 ms for 1,099,999
members, 4,400,144 retained mapping bytes, and 139,408/967,608 portable bytes.
This is one native reader on a Xeon Gold 6258R at 2.70 GHz; it does not prove
concurrent endpoint latency. The serialization buffer is server-only.

The remaining-byte export contract, exact-size acceptance, undersized rejection,
actual core/web BEAM boundaries and complete 100-view native workload passed in
[af2acf21](https://carverauto.buildbuddy.io/invocation/af2acf21-1ca0-4d63-b90a-76c3da8ad317).

Mapping lifetime admission and the dense-container export regression both failed
before their repairs in
[b618b699](https://carverauto.buildbuddy.io/invocation/b618b699-39a4-4d67-b5d3-3ba6e9dc8d2e):
the BEAM API admitted a third retained mapping, and a valid dense export returned
`OrdinalBudgetExceeded`. Both passed after repair in
[235268a9](https://carverauto.buildbuddy.io/invocation/235268a9-f2fe-4409-9dce-0ba18ff9c68f),
along with the native NIF/ordinal suites and existing core/web BEAM ABI lanes.
