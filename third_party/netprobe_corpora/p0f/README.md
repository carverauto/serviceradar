# p0f Signature Corpus

This directory vendors the upstream p0f fingerprint database as a separate,
replaceable corpus file.

## Upstream Corpus

- File: `p0f.fp`
- Source URL: `https://lcamtuf.coredump.cx/p0f3/releases/p0f-3.09b.tgz`
- Upstream project page: `https://lcamtuf.coredump.cx/p0f3/`
- Upstream release: `p0f-3.09b`
- Release last-modified: `Mon, 18 Apr 2016 17:03:37 GMT`
- Tarball sha256: `543b68638e739be5c3e818c3958c3b124ac0ccb8be62ba274b4241dbdec00e7f`
- `p0f.fp` sha256: `45f27bcc65de0f64bc69356dc0662e3366e05e67a0e98fd2251808e253b6be40`
- License: GNU LGPL 2.1, as stated in the upstream `p0f.fp` header.

ServiceRadar is Apache-2.0 licensed. The vendored upstream p0f database remains
under its original LGPL terms. Keep `p0f.fp` as a separate replaceable file and
preserve its copyright and license header.

## Local Additions

Do not edit `p0f.fp` directly. Treat it as frozen upstream data from the
`p0f-3.09b` release. ServiceRadar-specific signatures belong in
`serviceradar-additions.fp`, which is intentionally separate so operators can
replace or diff local additions independently from the upstream corpus.

See `CONTRIBUTING.md` for the signature submission, review, and lint workflow.
