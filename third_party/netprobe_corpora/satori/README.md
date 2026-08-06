# Satori Fingerprint Corpus

This directory vendors the fingerprint XML data from the maintained
Satori repository as a separately licensed, replaceable data corpus.

## Source

- Upstream: `https://github.com/xnih/satori`
- Commit: `73fa88fe6549995c68760be10631382df4ec1d1c`
- Commit date: `2025-12-23T23:08:33-07:00`
- Commit subject: `Add files via upload`
- Files vendored:
  - `fingerprints/*.xml` -> `xml/*.xml`
  - `LICENSE` -> `LICENSE-GPL-2.0.txt`
  - `README.md` -> `UPSTREAM-README.md`

Only the XML fingerprint data is vendored. ServiceRadar does not vendor
or copy Satori's Python runtime, pcap integration, or SSL/JA4 code.

## License Boundary

The vendored Satori XML files are licensed under GPLv2 by the upstream
project. Keep the GPLv2 license text and upstream README with the corpus,
and keep the XML files replaceable by operators.

ServiceRadar's Satori parser and matcher are independently authored
Apache-2.0 code that treats this directory as data. ServiceRadar-authored
fingerprint additions must live in separate ServiceRadar-owned files
rather than modifying upstream GPLv2 XML in place.

## Update Procedure

1. Clone or fetch `https://github.com/xnih/satori`.
2. Record the upstream commit SHA and commit date.
3. Copy `fingerprints/*.xml`, `LICENSE`, and `README.md` into this
   directory using the file layout above.
4. Regenerate `SHA256SUMS` from this directory.
5. Verify all XML files parse cleanly and record the fingerprint counts.
6. Run the ServiceRadar license lint to confirm the corpus boundary still
   excludes Satori code and includes only the GPLv2 data files.

Current fingerprint counts:

- `xml/browser.xml`: 22 `<fingerprint>` entries.
- `xml/dhcp.xml`: 481 `<fingerprint>` entries.
- `xml/dhcpv6.xml`: 9 `<fingerprint>` entries.
- `xml/dns.xml`: 48 `<fingerprint>` entries.
- `xml/icmp.xml`: 13 `<fingerprint>` entries.
- `xml/ntp.xml`: 25 `<fingerprint>` entries.
- `xml/sip.xml`: 25 `<fingerprint>` entries.
- `xml/smb.xml`: 89 `<fingerprint>` entries.
- `xml/ssh.xml`: 67 `<fingerprint>` entries.
- `xml/ssl.xml`: 51 `<fingerprint>` entries.
- `xml/tcp.xml`: 184 `<fingerprint>` entries.
- `xml/web.xml`: 67 `<fingerprint>` entries.
- `xml/webuseragent.xml`: 899 `<fingerprint>` entries.

Total: 1,980 `<fingerprint>` entries across 13 XML files.
