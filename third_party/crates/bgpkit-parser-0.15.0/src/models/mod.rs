/*!
`bgp-models` module defines the basic BGP and MRT message data structures.

This library aims to provide building blocks for downstream libraries working with BGP and MRT
messages such as MRT bgpkit-parser or BGP table constructor.

## Supported RFCs

Most of the structs defined in this library are named after the formal definitions in a number of
RFCs. Here is a list of them:

### BGP
- [X] [RFC 2042](https://datatracker.ietf.org/doc/html/rfc2042): Registering New BGP Attribute Types
- [X] [RFC 3392](https://datatracker.ietf.org/doc/html/rfc3392): Capabilities Advertisement with BGP-4
- [X] [RFC 4271](https://datatracker.ietf.org/doc/html/rfc4271): A Border Gateway Protocol 4 (BGP-4)
- [X] [RFC 5065](https://datatracker.ietf.org/doc/html/rfc5065): Autonomous System Confederations for BGP
- [X] [RFC 6793](https://datatracker.ietf.org/doc/html/rfc6793): BGP Support for Four-Octet Autonomous System (AS) Number Space
- [X] [RFC 7911](https://datatracker.ietf.org/doc/html/rfc7911): Advertisement of Multiple Paths in BGP (ADD-PATH)
- [X] [RFC 9072](https://datatracker.ietf.org/doc/html/rfc9072): Extended Optional Parameters Length for BGP OPEN Message Updates
- [X] [RFC 9234](https://datatracker.ietf.org/doc/html/rfc9234): Route Leak Prevention and Detection Using Roles in UPDATE and OPEN Messages

### MRT

- [X] [RFC 6396](https://datatracker.ietf.org/doc/html/rfc6396): Multi-Threaded Routing Toolkit (MRT) Routing Information Export Format
- [ ] [RFC 6397](https://datatracker.ietf.org/doc/html/rfc6397): Multi-Threaded Routing Toolkit (MRT) Border Gateway Protocol (BGP) Routing Information Export Format with Geo-Location Extensions
- [X] [RFC 8050](https://datatracker.ietf.org/doc/html/rfc8050): Multi-Threaded Routing Toolkit (MRT) Routing Information Export Format with BGP Additional Path Extensions

### Communities

#### Communities

- [X] [RFC 1977](https://datatracker.ietf.org/doc/html/rfc1977): BGP Communities Attribute

#### Extended Communities

- [X] [RFC 4360](https://datatracker.ietf.org/doc/html/rfc4360): BGP Extended Communities Attribute
- [X] [RFC 5668](https://datatracker.ietf.org/doc/html/rfc5668): 4-Octet AS Specific BGP Extended Community
- [X] [RFC 5701](https://datatracker.ietf.org/doc/html/rfc5701): IPv6 Address Specific BGP Extended Community Attribute
- [X] [RFC 7153](https://datatracker.ietf.org/doc/html/rfc7153): IANA Registries for BGP Extended Communities Updates 4360, 5701
- [X] [RFC 8097](https://datatracker.ietf.org/doc/html/rfc8097): BGP Prefix Origin Validation State Extended Community

#### Large Communities

- [X] [RFC 8092](https://datatracker.ietf.org/doc/html/rfc8092): BGP Large Communities

### Other Informational

- [RFC 4384](https://datatracker.ietf.org/doc/html/rfc4384): BGP Communities for Data Collection BCP 114
- [RFC 8195](https://datatracker.ietf.org/doc/html/rfc8195): Use of BGP Large Communities (informational)
- [RFC 8642](https://datatracker.ietf.org/doc/html/rfc8642): Policy Behavior for Well-Known BGP Communities

 */

mod bgp;
mod err;
mod mrt;
mod network;
pub mod rpki;

pub use bgp::*;
pub use err::BgpModelsError;
pub use mrt::*;
pub use network::*;
