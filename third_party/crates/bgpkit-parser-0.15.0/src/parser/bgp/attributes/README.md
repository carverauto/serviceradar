# BGP Path Attributes

## Unit Test Coverage

| Path Attribute           | RFC                | Codes | Unit Test |
|--------------------------|--------------------|-------|-----------|
| Origin                   | [RFC4271][rfc4271] | 1     | Yes       |
| AS Path                  | [RFC4271][rfc4271] | 2,17  | Yes       |
| Next Hop                 | [RFC4271][rfc4271] | 3     | Yes       |
| Multi Exit Discriminator | [RFC4271][rfc4271] | 4     | Yes       |
| Local Preference         | [RFC4271][rfc4271] | 5     | Yes       |
| Atomic Aggregate         | [RFC4271][rfc4271] | 6     | Yes       |
| Aggregate                | [RFC4271][rfc4271] | 7,18  | Yes       |
| Community                | [RFC1997][rfc1997] | 8     | Yes       |
| Originator ID            | [RFC4456][rfc4456] | 9     | Yes       |
| Cluster List             | [RFC4456][rfc4456] | 10,13 | Yes       |
| MP NLRI                  | [RFC4760][rfc4760] | 14,15 | Yes       |
| Extended Community       | [RFC4360][rfc4360] | 16,25 | Yes       |
| Large Community          | [RFC8092][rfc8092] | 32    | Yes       |
| Only To Customer         | [RFC9234][rfc9234] | 35    | Yes       |

[rfc1997]: https://datatracker.ietf.org/doc/html/rfc1997
[rfc4271]: https://datatracker.ietf.org/doc/html/rfc4271#section-4.3
[rfc4360]: https://datatracker.ietf.org/doc/html/rfc4360
[rfc4456]: https://datatracker.ietf.org/doc/html/rfc4456
[rfc4760]: https://datatracker.ietf.org/doc/html/rfc4760
[rfc8092]: https://datatracker.ietf.org/doc/html/rfc8092
[rfc9234]: https://datatracker.ietf.org/doc/html/rfc9234
[iana-bgp]: https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml