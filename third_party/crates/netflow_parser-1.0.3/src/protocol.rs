use nom::IResult;
use nom_derive::*;
use serde::Serialize;

/// IANA Protocol Numbers as defined in RFC 5237.
///
/// Maps protocol identifiers to their numeric values for IP packet headers.
/// These protocol numbers are commonly used in NetFlow/IPFIX for the
/// `protocolIdentifier` field to indicate the transport layer protocol.
///
/// # Common Protocols
///
/// | Protocol | Number | Description |
/// |----------|--------|-------------|
/// | ICMP | 1 | Internet Control Message Protocol |
/// | TCP | 6 | Transmission Control Protocol |
/// | UDP | 17 | User Datagram Protocol |
/// | IPv6 | 41 | IPv6 Encapsulation |
/// | ICMP6 | 58 | ICMP for IPv6 |
/// | GRE | 47 | Generic Routing Encapsulation |
/// | ESP | 50 | Encapsulating Security Payload |
/// | AH | 51 | Authentication Header |
/// | SCTP | 132 | Stream Control Transmission Protocol |
///
/// # Examples
///
/// ```
/// use netflow_parser::protocol::ProtocolTypes;
///
/// // Common protocol numbers
/// assert_eq!(u8::from(ProtocolTypes::Tcp), 6);
/// assert_eq!(u8::from(ProtocolTypes::Udp), 17);
/// assert_eq!(u8::from(ProtocolTypes::Icmp), 1);
///
/// // IPv6 protocols
/// assert_eq!(u8::from(ProtocolTypes::Ipv6), 41);
/// assert_eq!(u8::from(ProtocolTypes::Ipv6Icmp), 58);
/// ```
///
/// # References
///
/// See [IANA Protocol Numbers](https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml)
/// for the complete official registry.
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub enum ProtocolTypes {
    Hopopt,
    Icmp,
    Igmp,
    Ggp,
    Ipv4,
    St,
    Tcp,
    Cbt,
    Egp,
    Igp,
    Bbcrccmon,
    Nvpii,
    Pup,
    Argus,
    Emcon,
    Xnet,
    Chaos,
    Udp,
    Mux,
    Dcnmeas,
    Hmp,
    Prm,
    Xnxidp,
    Trunk1,
    Trunk2,
    Leaf1,
    Leaf2,
    Rdp,
    Irtp,
    Isotp4,
    Netblt,
    Mfensp,
    Meritinp,
    Dccp,
    Threepc,
    Idpr,
    Xtp,
    Ddp,
    Idprcmtp,
    Tppp,
    Il,
    Ipv6,
    Sdrp,
    Ipv6Route,
    Ipv6Frag,
    Idrp,
    Rsvp,
    Gre,
    Dsr,
    Bna,
    Esp,
    Ah,
    Inlsp,
    Swipe,
    Narp,
    Mobile,
    Tlsp,
    Skip,
    Ipv6Icmp,
    Ipv6Nonxt,
    Ipv6Opts,
    Anydistributedprotocol,
    Cftp,
    Anylocalnetwork,
    Satexpak,
    Kryptolan,
    Rvd,
    Ippc,
    Anydistributedfilesystem,
    Satmon,
    Visa,
    Ipcv,
    Cpnx,
    Cphb,
    Wsn,
    Pvp,
    Brsatmon,
    Sunnd,
    Wbmon,
    Wbexpak,
    Isoip,
    Vmtp,
    Securevmtp,
    Vines,
    Iptm,
    Nsfnetigp,
    Dgp,
    Tcf,
    Eigrp,
    Ospfigp,
    Spriterpc,
    Larp,
    Mtp,
    Ax25,
    Ipip,
    Micp,
    Sccsp,
    Etherip,
    Encap,
    Anyprivateencryptionscheme,
    Gmtp,
    Ifmp,
    Pnni,
    Pim,
    Aris,
    Scps,
    Qnx,
    An,
    Ipcomp,
    Snp,
    Compaqpeer,
    Ipxinip,
    Vrrp,
    Pgm,
    Any0Hopprotocol,
    L2Tp,
    Ddx,
    Iatp,
    Stp,
    Srp,
    Uti,
    Smp,
    Sm,
    Ptp,
    Isisoveripv4,
    Fire,
    Crtp,
    Crudp,
    Sscopmce,
    Iplt,
    Sps,
    Pipe,
    Sctp,
    Fc,
    Rsvpe2Eignore,
    Mobilityheader,
    Udplite,
    Mplsinip,
    Manet,
    Hip,
    Shim6,
    Wesp,
    Rohc,
    Ethernet,
    Aggfrag,
    /// Unrecognized or unassigned protocol number, carrying its original value.
    ///
    /// This variant only holds values that are **not** covered by a named variant
    /// (i.e., 145–254). Constructing `Unknown` with a value that has a named variant
    /// (e.g., `Unknown(6)`) will work but is not canonical — `From<u8>` always
    /// produces the named variant, so round-tripping through `u8` will not preserve
    /// `Unknown(6)` (it becomes `Tcp`).
    Unknown(u8),
    Reserved,
}

impl PartialOrd for ProtocolTypes {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ProtocolTypes {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u8::from(*self).cmp(&u8::from(*other))
    }
}

impl ProtocolTypes {
    /// Parse a `ProtocolTypes` value from a byte slice by reading a single `u8`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u8::parse(input)?;
        Ok((remaining, Self::from(value)))
    }
}

impl From<ProtocolTypes> for u8 {
    fn from(item: ProtocolTypes) -> Self {
        match item {
            ProtocolTypes::Hopopt => 0,
            ProtocolTypes::Icmp => 1,
            ProtocolTypes::Igmp => 2,
            ProtocolTypes::Ggp => 3,
            ProtocolTypes::Ipv4 => 4,
            ProtocolTypes::St => 5,
            ProtocolTypes::Tcp => 6,
            ProtocolTypes::Cbt => 7,
            ProtocolTypes::Egp => 8,
            ProtocolTypes::Igp => 9,
            ProtocolTypes::Bbcrccmon => 10,
            ProtocolTypes::Nvpii => 11,
            ProtocolTypes::Pup => 12,
            ProtocolTypes::Argus => 13,
            ProtocolTypes::Emcon => 14,
            ProtocolTypes::Xnet => 15,
            ProtocolTypes::Chaos => 16,
            ProtocolTypes::Udp => 17,
            ProtocolTypes::Mux => 18,
            ProtocolTypes::Dcnmeas => 19,
            ProtocolTypes::Hmp => 20,
            ProtocolTypes::Prm => 21,
            ProtocolTypes::Xnxidp => 22,
            ProtocolTypes::Trunk1 => 23,
            ProtocolTypes::Trunk2 => 24,
            ProtocolTypes::Leaf1 => 25,
            ProtocolTypes::Leaf2 => 26,
            ProtocolTypes::Rdp => 27,
            ProtocolTypes::Irtp => 28,
            ProtocolTypes::Isotp4 => 29,
            ProtocolTypes::Netblt => 30,
            ProtocolTypes::Mfensp => 31,
            ProtocolTypes::Meritinp => 32,
            ProtocolTypes::Dccp => 33,
            ProtocolTypes::Threepc => 34,
            ProtocolTypes::Idpr => 35,
            ProtocolTypes::Xtp => 36,
            ProtocolTypes::Ddp => 37,
            ProtocolTypes::Idprcmtp => 38,
            ProtocolTypes::Tppp => 39,
            ProtocolTypes::Il => 40,
            ProtocolTypes::Ipv6 => 41,
            ProtocolTypes::Sdrp => 42,
            ProtocolTypes::Ipv6Route => 43,
            ProtocolTypes::Ipv6Frag => 44,
            ProtocolTypes::Idrp => 45,
            ProtocolTypes::Rsvp => 46,
            ProtocolTypes::Gre => 47,
            ProtocolTypes::Dsr => 48,
            ProtocolTypes::Bna => 49,
            ProtocolTypes::Esp => 50,
            ProtocolTypes::Ah => 51,
            ProtocolTypes::Inlsp => 52,
            ProtocolTypes::Swipe => 53,
            ProtocolTypes::Narp => 54,
            ProtocolTypes::Mobile => 55,
            ProtocolTypes::Tlsp => 56,
            ProtocolTypes::Skip => 57,
            ProtocolTypes::Ipv6Icmp => 58,
            ProtocolTypes::Ipv6Nonxt => 59,
            ProtocolTypes::Ipv6Opts => 60,
            ProtocolTypes::Anydistributedprotocol => 61,
            ProtocolTypes::Cftp => 62,
            ProtocolTypes::Anylocalnetwork => 63,
            ProtocolTypes::Satexpak => 64,
            ProtocolTypes::Kryptolan => 65,
            ProtocolTypes::Rvd => 66,
            ProtocolTypes::Ippc => 67,
            ProtocolTypes::Anydistributedfilesystem => 68,
            ProtocolTypes::Satmon => 69,
            ProtocolTypes::Visa => 70,
            ProtocolTypes::Ipcv => 71,
            ProtocolTypes::Cpnx => 72,
            ProtocolTypes::Cphb => 73,
            ProtocolTypes::Wsn => 74,
            ProtocolTypes::Pvp => 75,
            ProtocolTypes::Brsatmon => 76,
            ProtocolTypes::Sunnd => 77,
            ProtocolTypes::Wbmon => 78,
            ProtocolTypes::Wbexpak => 79,
            ProtocolTypes::Isoip => 80,
            ProtocolTypes::Vmtp => 81,
            ProtocolTypes::Securevmtp => 82,
            ProtocolTypes::Vines => 83,
            ProtocolTypes::Iptm => 84,
            ProtocolTypes::Nsfnetigp => 85,
            ProtocolTypes::Dgp => 86,
            ProtocolTypes::Tcf => 87,
            ProtocolTypes::Eigrp => 88,
            ProtocolTypes::Ospfigp => 89,
            ProtocolTypes::Spriterpc => 90,
            ProtocolTypes::Larp => 91,
            ProtocolTypes::Mtp => 92,
            ProtocolTypes::Ax25 => 93,
            ProtocolTypes::Ipip => 94,
            ProtocolTypes::Micp => 95,
            ProtocolTypes::Sccsp => 96,
            ProtocolTypes::Etherip => 97,
            ProtocolTypes::Encap => 98,
            ProtocolTypes::Anyprivateencryptionscheme => 99,
            ProtocolTypes::Gmtp => 100,
            ProtocolTypes::Ifmp => 101,
            ProtocolTypes::Pnni => 102,
            ProtocolTypes::Pim => 103,
            ProtocolTypes::Aris => 104,
            ProtocolTypes::Scps => 105,
            ProtocolTypes::Qnx => 106,
            ProtocolTypes::An => 107,
            ProtocolTypes::Ipcomp => 108,
            ProtocolTypes::Snp => 109,
            ProtocolTypes::Compaqpeer => 110,
            ProtocolTypes::Ipxinip => 111,
            ProtocolTypes::Vrrp => 112,
            ProtocolTypes::Pgm => 113,
            ProtocolTypes::Any0Hopprotocol => 114,
            ProtocolTypes::L2Tp => 115,
            ProtocolTypes::Ddx => 116,
            ProtocolTypes::Iatp => 117,
            ProtocolTypes::Stp => 118,
            ProtocolTypes::Srp => 119,
            ProtocolTypes::Uti => 120,
            ProtocolTypes::Smp => 121,
            ProtocolTypes::Sm => 122,
            ProtocolTypes::Ptp => 123,
            ProtocolTypes::Isisoveripv4 => 124,
            ProtocolTypes::Fire => 125,
            ProtocolTypes::Crtp => 126,
            ProtocolTypes::Crudp => 127,
            ProtocolTypes::Sscopmce => 128,
            ProtocolTypes::Iplt => 129,
            ProtocolTypes::Sps => 130,
            ProtocolTypes::Pipe => 131,
            ProtocolTypes::Sctp => 132,
            ProtocolTypes::Fc => 133,
            ProtocolTypes::Rsvpe2Eignore => 134,
            ProtocolTypes::Mobilityheader => 135,
            ProtocolTypes::Udplite => 136,
            ProtocolTypes::Mplsinip => 137,
            ProtocolTypes::Manet => 138,
            ProtocolTypes::Hip => 139,
            ProtocolTypes::Shim6 => 140,
            ProtocolTypes::Wesp => 141,
            ProtocolTypes::Rohc => 142,
            ProtocolTypes::Ethernet => 143,
            ProtocolTypes::Aggfrag => 144,
            ProtocolTypes::Unknown(v) => v,
            ProtocolTypes::Reserved => 255,
        }
    }
}

impl From<u8> for ProtocolTypes {
    fn from(item: u8) -> Self {
        match item {
            0 => ProtocolTypes::Hopopt,
            1 => ProtocolTypes::Icmp,
            2 => ProtocolTypes::Igmp,
            3 => ProtocolTypes::Ggp,
            4 => ProtocolTypes::Ipv4,
            5 => ProtocolTypes::St,
            6 => ProtocolTypes::Tcp,
            7 => ProtocolTypes::Cbt,
            8 => ProtocolTypes::Egp,
            9 => ProtocolTypes::Igp,
            10 => ProtocolTypes::Bbcrccmon,
            11 => ProtocolTypes::Nvpii,
            12 => ProtocolTypes::Pup,
            13 => ProtocolTypes::Argus,
            14 => ProtocolTypes::Emcon,
            15 => ProtocolTypes::Xnet,
            16 => ProtocolTypes::Chaos,
            17 => ProtocolTypes::Udp,
            18 => ProtocolTypes::Mux,
            19 => ProtocolTypes::Dcnmeas,
            20 => ProtocolTypes::Hmp,
            21 => ProtocolTypes::Prm,
            22 => ProtocolTypes::Xnxidp,
            23 => ProtocolTypes::Trunk1,
            24 => ProtocolTypes::Trunk2,
            25 => ProtocolTypes::Leaf1,
            26 => ProtocolTypes::Leaf2,
            27 => ProtocolTypes::Rdp,
            28 => ProtocolTypes::Irtp,
            29 => ProtocolTypes::Isotp4,
            30 => ProtocolTypes::Netblt,
            31 => ProtocolTypes::Mfensp,
            32 => ProtocolTypes::Meritinp,
            33 => ProtocolTypes::Dccp,
            34 => ProtocolTypes::Threepc,
            35 => ProtocolTypes::Idpr,
            36 => ProtocolTypes::Xtp,
            37 => ProtocolTypes::Ddp,
            38 => ProtocolTypes::Idprcmtp,
            39 => ProtocolTypes::Tppp,
            40 => ProtocolTypes::Il,
            41 => ProtocolTypes::Ipv6,
            42 => ProtocolTypes::Sdrp,
            43 => ProtocolTypes::Ipv6Route,
            44 => ProtocolTypes::Ipv6Frag,
            45 => ProtocolTypes::Idrp,
            46 => ProtocolTypes::Rsvp,
            47 => ProtocolTypes::Gre,
            48 => ProtocolTypes::Dsr,
            49 => ProtocolTypes::Bna,
            50 => ProtocolTypes::Esp,
            51 => ProtocolTypes::Ah,
            52 => ProtocolTypes::Inlsp,
            53 => ProtocolTypes::Swipe,
            54 => ProtocolTypes::Narp,
            55 => ProtocolTypes::Mobile,
            56 => ProtocolTypes::Tlsp,
            57 => ProtocolTypes::Skip,
            58 => ProtocolTypes::Ipv6Icmp,
            59 => ProtocolTypes::Ipv6Nonxt,
            60 => ProtocolTypes::Ipv6Opts,
            61 => ProtocolTypes::Anydistributedprotocol,
            62 => ProtocolTypes::Cftp,
            63 => ProtocolTypes::Anylocalnetwork,
            64 => ProtocolTypes::Satexpak,
            65 => ProtocolTypes::Kryptolan,
            66 => ProtocolTypes::Rvd,
            67 => ProtocolTypes::Ippc,
            68 => ProtocolTypes::Anydistributedfilesystem,
            69 => ProtocolTypes::Satmon,
            70 => ProtocolTypes::Visa,
            71 => ProtocolTypes::Ipcv,
            72 => ProtocolTypes::Cpnx,
            73 => ProtocolTypes::Cphb,
            74 => ProtocolTypes::Wsn,
            75 => ProtocolTypes::Pvp,
            76 => ProtocolTypes::Brsatmon,
            77 => ProtocolTypes::Sunnd,
            78 => ProtocolTypes::Wbmon,
            79 => ProtocolTypes::Wbexpak,
            80 => ProtocolTypes::Isoip,
            81 => ProtocolTypes::Vmtp,
            82 => ProtocolTypes::Securevmtp,
            83 => ProtocolTypes::Vines,
            84 => ProtocolTypes::Iptm,
            85 => ProtocolTypes::Nsfnetigp,
            86 => ProtocolTypes::Dgp,
            87 => ProtocolTypes::Tcf,
            88 => ProtocolTypes::Eigrp,
            89 => ProtocolTypes::Ospfigp,
            90 => ProtocolTypes::Spriterpc,
            91 => ProtocolTypes::Larp,
            92 => ProtocolTypes::Mtp,
            93 => ProtocolTypes::Ax25,
            94 => ProtocolTypes::Ipip,
            95 => ProtocolTypes::Micp,
            96 => ProtocolTypes::Sccsp,
            97 => ProtocolTypes::Etherip,
            98 => ProtocolTypes::Encap,
            99 => ProtocolTypes::Anyprivateencryptionscheme,
            100 => ProtocolTypes::Gmtp,
            101 => ProtocolTypes::Ifmp,
            102 => ProtocolTypes::Pnni,
            103 => ProtocolTypes::Pim,
            104 => ProtocolTypes::Aris,
            105 => ProtocolTypes::Scps,
            106 => ProtocolTypes::Qnx,
            107 => ProtocolTypes::An,
            108 => ProtocolTypes::Ipcomp,
            109 => ProtocolTypes::Snp,
            110 => ProtocolTypes::Compaqpeer,
            111 => ProtocolTypes::Ipxinip,
            112 => ProtocolTypes::Vrrp,
            113 => ProtocolTypes::Pgm,
            114 => ProtocolTypes::Any0Hopprotocol,
            115 => ProtocolTypes::L2Tp,
            116 => ProtocolTypes::Ddx,
            117 => ProtocolTypes::Iatp,
            118 => ProtocolTypes::Stp,
            119 => ProtocolTypes::Srp,
            120 => ProtocolTypes::Uti,
            121 => ProtocolTypes::Smp,
            122 => ProtocolTypes::Sm,
            123 => ProtocolTypes::Ptp,
            124 => ProtocolTypes::Isisoveripv4,
            125 => ProtocolTypes::Fire,
            126 => ProtocolTypes::Crtp,
            127 => ProtocolTypes::Crudp,
            128 => ProtocolTypes::Sscopmce,
            129 => ProtocolTypes::Iplt,
            130 => ProtocolTypes::Sps,
            131 => ProtocolTypes::Pipe,
            132 => ProtocolTypes::Sctp,
            133 => ProtocolTypes::Fc,
            134 => ProtocolTypes::Rsvpe2Eignore,
            135 => ProtocolTypes::Mobilityheader,
            136 => ProtocolTypes::Udplite,
            137 => ProtocolTypes::Mplsinip,
            138 => ProtocolTypes::Manet,
            139 => ProtocolTypes::Hip,
            140 => ProtocolTypes::Shim6,
            141 => ProtocolTypes::Wesp,
            142 => ProtocolTypes::Rohc,
            143 => ProtocolTypes::Ethernet,
            144 => ProtocolTypes::Aggfrag,
            255 => ProtocolTypes::Reserved,
            _ => ProtocolTypes::Unknown(item),
        }
    }
}

#[cfg(test)]
mod protocol_lookup_tests {

    use super::ProtocolTypes;

    use insta::assert_yaml_snapshot;

    #[test]
    fn it_tests_protocol_types() {
        let protocols = (0..=144).map(ProtocolTypes::from).collect::<Vec<_>>();
        assert_yaml_snapshot!(protocols);
    }

    #[test]
    fn it_tests_unknown_and_reserved_protocols() {
        // Values 145-254 should all map to Unknown(n)
        for i in 145..=254u8 {
            assert_eq!(ProtocolTypes::from(i), ProtocolTypes::Unknown(i));
        }
        // Value 255 should map to Reserved
        assert_eq!(ProtocolTypes::from(255u8), ProtocolTypes::Reserved);
    }

    #[test]
    fn it_tests_protocol_round_trip() {
        // Every u8 value should round-trip: u8 -> ProtocolTypes -> u8
        for i in 0..=255u8 {
            let protocol = ProtocolTypes::from(i);
            let back: u8 = protocol.into();
            assert_eq!(i, back, "round-trip failed for protocol {i}");
        }
    }
}
