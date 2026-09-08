# Recog Corpus

ServiceRadar vendors Rapid7 Recog XML fingerprints as a replaceable corpus for
banner-derived passive and active fingerprint matching.

## Upstream

- Source URL: https://github.com/rapid7/recog
- Release tag: `v3.1.25`
- Tag object: `4bbf243f5186fb28e33c0d65e84ccd91763d8b82`
- Commit SHA: `2d99f217e70aeca8f1c9a1fb298f88a2211292a3`
- Commit date: 2026-05-20T12:15:03+05:30
- Commit subject: `Updated Freebsd regex  and fixed broken pipeline`

## License

The pinned upstream release contains:

- `COPYING` with the BSD-2-Clause license text.
- `LICENSE` in Debian copyright format, declaring `Files: *` under
  `License: BSD-2-clause`.

No separate `NOTICE` file exists at the pinned release. Preserve both copied
files when bumping the corpus.

## Vendored Contents

- `xml/*.xml`: 50 Recog XML fingerprint files.
- `xml/fingerprints.xsd`: upstream schema used by Recog validators.
- `identifiers/*.txt`: upstream controlled identifier lists used by the XML
  corpus.
- `SHA256SUMS`: sha256 manifest for every vendored XML fingerprint file.
- `IDENTIFIER_SHA256SUMS`: sha256 manifest for vendored identifier lists.

Top-level checksums:

- `COPYING`: `01fdfefde10cc10049c2924f6d9d4746d398d770af5c133ebced1fc41eaad38a`
- `LICENSE`: `3ae091fc24e63ef94bb61353457021afc6f8a6b4573e09e538ce2e023708078f`
- `xml/fingerprints.xsd`: `a9cdd5935360549b616aef892d603d9cf2b941e6f9f346f33041cc4f0fa69609`
- `SHA256SUMS`: `0e334bf22024b0490e75c9e0f4c7019ce2adee1789cd00cb986387c3d842ef29`
- `IDENTIFIER_SHA256SUMS`: `e8fde03fd473c49caf2256c9c842b9e61e5a0672f4161f171ee8f0083bae67fa`

## Upstream Bump Procedure

1. Clone the desired Recog release tag into a temporary directory.
2. Verify `COPYING` and `LICENSE` still describe a permissive BSD-compatible
   license. Stop and request review if the license changes or a new `NOTICE`
   file appears.
3. Replace `xml/*.xml`, `xml/fingerprints.xsd`, and `identifiers/*.txt` from
   the upstream tag.
4. Regenerate manifests:

   ```bash
   (cd third_party/netprobe_corpora/recog && shasum -a 256 xml/*.xml > SHA256SUMS)
   (cd third_party/netprobe_corpora/recog && shasum -a 256 identifiers/*.txt > IDENTIFIER_SHA256SUMS)
   ```

5. Update this README with the new tag, commit SHA, dates, and top-level
   checksums.
6. Run the Recog parser validation suite once §32.4 lands.

## Audit Notes

Dependency and text audit at the pinned tag found no references to FoxIO,
JA4+, `huginn-net`, or FoxIO-1.1 licensed methods. Some XML examples contain
product banners with phrases such as "non-commercial"; those are matched
service banner samples, not corpus license terms.
