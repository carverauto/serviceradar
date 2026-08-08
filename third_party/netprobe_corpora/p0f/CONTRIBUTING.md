# ServiceRadar p0f Additions

ServiceRadar-specific TCP fingerprints belong in
`third_party/netprobe_corpora/p0f/serviceradar-additions.fp`. Do not edit the frozen
upstream `p0f.fp` corpus.

## Submission Format

Add entries using the same p0f grammar parsed by
`rust/netprobe/src/p0f_corpus.rs`:

```text
[tcp:request]
label = s:<class>:<name>:<flavor>
sig = <ver>:<ttl>:<olen>:<mss>:<wsize>,<scale>:<olayout>:<quirks>:<pclass>
```

Use comments above each new block to capture the observed device, firmware or
OS version, packet source, and reviewer. Keep packet captures and customer
identifiers out of the corpus file.

## Review SLA

New operator-submitted signatures should receive maintainer triage within five
business days. A signature is mergeable when it:

- Parses with `make lint-p0f-additions`.
- Includes enough provenance in comments for a future maintainer to understand
  why the signature exists.
- Does not duplicate a frozen upstream `p0f.fp` signature.
- Has been checked against at least one fixture or observed SYN packet.

## License

ServiceRadar-authored additions default to CC0-1.0 unless a future entry
explicitly states otherwise. Contributions must only include signatures the
contributor has the right to dedicate under that license. The upstream
`p0f.fp` file remains under its original LGPL-2.1 terms and is kept separate.

## Linting

Run this before submitting a change:

```bash
make lint-p0f-additions
```

The target parses `serviceradar-additions.fp` with the in-tree parser so grammar
breakage is caught before merge. The build also appends this file to the frozen
upstream corpus when generating the bundled p0f matcher.
