# Implementation choices

## Sound, medium confidence

### Local journal format and provisional sizing

When: local spool pass.

When a fragment finishes, the spool writes its media bytes and asks the operating
system to sync them, then does the same for a small checksummed journal record.
Only the returned byte map makes that fragment readable. After an interrupted
write, recovery checks each complete record and its media digest before removing
an unfinished tail. A complete corrupt record stops recovery instead of silently
discarding footage. A final journal record seals the block; renaming a file is
not the commit boundary.

The plan required this ordering but left the journal encoding and initial limits
open. The implementation uses bounded JSON records with length prefixes and
SHA-256 checksums. Initial defaults are 8 MiB per fragment, 64 MiB per block,
512 fragments, and 10 seconds per fragment; these are conservative experiment
settings, not measured deployment capacity or performance promises. Deployment
profiling can lower or raise them within explicit ceilings.

This is sound because recovery and playback consume the same committed byte map,
and all reads, records and block sizes have finite limits. The filesystem must
support file and directory sync. The guarantee covers the local node only;
another node cannot recover footage that never reached an archive.

## Sound, high confidence

### Preserve unknown clock mappings

When: local spool and packaging boundary.

A camera can supply media timestamps without establishing what time of day they
represent. The packager carries an explicit unknown UTC mapping in that case,
and the spool preserves it. It does not substitute the server's current time.
When a mapping is available, its media origin and uncertainty travel with the
recording. This enables later timeline code to distinguish established capture
time from incomplete clock evidence.

The plan required honest clock provenance but did not fix the in-process shape.
The packager owns clock validation; storage persists a bounded copy of that
context. Disk block names depend only on source, profile, recorder epoch and
block sequence. Changing clock metadata cannot create a second copy of the same
block identity. This is sound because an unsupported clock claim stays visible
instead of becoming a false timestamp in exported evidence.
