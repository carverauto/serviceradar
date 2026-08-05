# ServiceRadar Recog Additions

ServiceRadar-specific banner fingerprints belong in
`third_party/netprobe_corpora/recog/serviceradar-recog-additions.xml`. Do not edit the
frozen upstream Rapid7 Recog XML files under `xml/` for local signatures.

## Submission Format

Add fingerprints using the same Recog XML shape parsed from upstream files, plus
a required `service` attribute so a single local additions file can feed the
right matcher bucket:

```xml
<fingerprint service="http_server" pattern="^ExampleServer/([0-9.]+)" flags="REG_ICASE">
  <description>ExampleServer HTTP banner</description>
  <example>ExampleServer/1.2.3</example>
  <param pos="0" name="service.vendor" value="Example"/>
  <param pos="0" name="service.product" value="ExampleServer"/>
  <param pos="1" name="service.version"/>
  <param pos="0" name="os.family" value="Linux"/>
</fingerprint>
```

Accepted `service` values are:

- `http_server`
- `ssh_banner`
- `smb_version`
- `ftp_banner`
- `smtp_banner`
- `telnet_banner`
- `snmp_banner`
- `sip_banner`
- `rdp_banner`
- `dns_version`

Use comments above each new fingerprint to capture the observed device,
firmware or service version, banner source, and reviewer. Keep packet captures,
raw customer identifiers, hostnames, IP addresses, and secrets out of the
corpus file.

## Review SLA

New operator-submitted signatures should receive maintainer triage within five
business days. A signature is mergeable when it:

- Parses with `make lint-recog-additions`.
- Includes enough provenance in comments for a future maintainer to understand
  why the signature exists.
- Does not duplicate a frozen upstream Recog signature.
- Has been checked against at least one fixture or observed banner.

## License

ServiceRadar-authored additions default to CC0-1.0 unless a future fingerprint
explicitly states otherwise. Contributions must only include signatures the
contributor has the right to dedicate under that license. The upstream Rapid7
Recog corpus remains under its original BSD-2-Clause terms and is kept
separate.

## Linting

Run this before submitting a change:

```bash
make lint-recog-additions
```

The target verifies the CC0 license header and compiles the netprobe Recog
tables, which parses `serviceradar-recog-additions.xml` with the same build-time
parser used for production.

## Quarterly Upstream Bumps

When bumping Rapid7 Recog, replace only files copied from upstream:
`xml/*.xml`, `xml/fingerprints.xsd`, `identifiers/*.txt`, `COPYING`, and
`LICENSE`. Regenerate `SHA256SUMS` and `IDENTIFIER_SHA256SUMS`, update
`README.md` with the new release metadata, and rerun:

```bash
make lint-recog-additions
bash scripts/check-netprobe-fingerprint-licenses.sh
```

Do not overwrite `serviceradar-recog-additions.xml` during upstream bumps.
