/// This type has been deprecated please use [IpNumber] instead.
///
/// IPv6 headers have a field called `traffic_class` which has nothing
/// to do this enum. This unlucky coincedence got even the developer
/// of this library confused enough to write that the next header number
/// should be written into the `traffic_class` field instead of the
/// `next_header` field.
///
/// To avoid such confusions in the future the enum has been renamed
/// to [IpNumber], which also closer to the name
/// "Assigned Internet Protocol Numbers" used on iana.org .
#[deprecated(since = "0.10.1", note = "Please use the type IpNumber instead")]
pub type IpTrafficClass = IpNumber;

/// Identifiers for the next_header field in ipv6 headers and protocol field in ipv4 headers.
///
/// You can access the underlying `u8` value by using `.0` and any `u8`
/// can be converted to an `IpNumber`:
///
/// ```
/// use etherparse::IpNumber;
///
/// assert_eq!(IpNumber::TCP.0, 6);
/// assert_eq!(IpNumber::TCP, IpNumber(6));
///
/// // convert to IpNumber using the from & into trait
/// let ip_num: IpNumber = 6.into();
/// assert_eq!(IpNumber::TCP, ip_num);
///
/// // convert to u8 using the from & into trait
/// let num: u8 = IpNumber::TCP.into();
/// assert_eq!(6, num);
/// ```
///
/// The constants are also defined in the `ip_number` module so they can
/// be used without the need to write `IpNumber::` in front of them:
///
/// ```
/// use etherparse::{ip_number::TCP, IpNumber};
///
/// assert_eq!(TCP, IpNumber::TCP);
/// ```
///
/// The list original values were copied from
/// <https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml>
#[derive(PartialEq, Eq, Clone, Copy, Hash, Ord, PartialOrd)]
pub struct IpNumber(pub u8);

impl IpNumber {
    /// IPv6 Hop-by-Hop Option \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    pub const IPV6_HEADER_HOP_BY_HOP: IpNumber = Self(0);
    /// Internet Control Message \[[RFC792](https://datatracker.ietf.org/doc/html/rfc792)\]
    pub const ICMP: IpNumber = Self(1);
    /// Internet Group Management \[[RFC1112](https://datatracker.ietf.org/doc/html/rfc1112)\]
    pub const IGMP: IpNumber = Self(2);
    /// Gateway-to-Gateway \[[RFC823](https://datatracker.ietf.org/doc/html/rfc823)\]
    pub const GGP: IpNumber = Self(3);
    /// IPv4 encapsulation \[[RFC2003](https://datatracker.ietf.org/doc/html/rfc2003)\]
    pub const IPV4: IpNumber = Self(4);
    /// Stream \[[RFC1190](https://datatracker.ietf.org/doc/html/rfc1190)\] \[[RFC1819](https://datatracker.ietf.org/doc/html/rfc1819)\]
    pub const STREAM: IpNumber = Self(5);
    /// Transmission Control \[[RFC793](https://datatracker.ietf.org/doc/html/rfc793)\]
    pub const TCP: IpNumber = Self(6);
    /// CBT \[Tony_Ballardie\]
    pub const CBT: IpNumber = Self(7);
    /// Exterior Gateway Protocol \[[RFC888](https://datatracker.ietf.org/doc/html/rfc888)\] \[David_Mills\]
    pub const EGP: IpNumber = Self(8);
    /// any private interior gateway (used by Cisco for their IGRP) \[Internet_Assigned_Numbers_Authority\]
    pub const IGP: IpNumber = Self(9);
    /// BBN RCC Monitoring \[Steve_Chipman\]
    pub const BBN_RCC_MON: IpNumber = Self(10);
    /// Network Voice Protocol \[[RFC741](https://datatracker.ietf.org/doc/html/rfc741)\]\[Steve_Casner\]
    pub const NVP_II: IpNumber = Self(11);
    /// PUP
    pub const PUP: IpNumber = Self(12);
    /// ARGUS (deprecated) \[Robert_W_Scheifler\]
    pub const ARGUS: IpNumber = Self(13);
    /// EMCON \[mystery contact\]
    pub const EMCON: IpNumber = Self(14);
    /// Cross Net Debugger \[Haverty, J., "XNET Formats for Internet Protocol Version 4", IEN 158, October 1980.\]\[Jack_Haverty\]
    pub const XNET: IpNumber = Self(15);
    /// Chaos \[J_Noel_Chiappa\]
    pub const CHAOS: IpNumber = Self(16);
    /// User Datagram \[[RFC768](https://datatracker.ietf.org/doc/html/rfc768)\]\[Jon_Postel\]
    pub const UDP: IpNumber = Self(17);
    /// Multiplexing \[Cohen, D. and J. Postel, "Multiplexing Protocol", IEN 90, USC/Information Sciences Institute, May 1979.\]\[Jon_Postel\]
    pub const MUX: IpNumber = Self(18);
    /// DCN Measurement Subsystems \[David_Mills\]
    pub const DCN_MEAS: IpNumber = Self(19);
    /// Host Monitoring \[[RFC869](https://datatracker.ietf.org/doc/html/rfc869)\]\[Bob_Hinden\]
    pub const HMP: IpNumber = Self(20);
    /// Packet Radio Measurement \[Zaw_Sing_Su\]
    pub const PRM: IpNumber = Self(21);
    /// XEROX NS IDP
    pub const XNS_IDP: IpNumber = Self(22);
    /// Trunk-1 \[Barry_Boehm\]
    pub const TRUNK1: IpNumber = Self(23);
    /// Trunk-2 \[Barry_Boehm\]
    pub const TRUNK2: IpNumber = Self(24);
    /// Leaf-1 \[Barry_Boehm\]
    pub const LEAF1: IpNumber = Self(25);
    /// Leaf-2 \[Barry_Boehm\]
    pub const LEAF2: IpNumber = Self(26);
    /// Reliable Data Protocol \[[RFC908](https://datatracker.ietf.org/doc/html/rfc908)\] \[Bob_Hinden\]
    pub const RDP: IpNumber = Self(27);
    /// Internet Reliable Transaction \[[RFC938](https://datatracker.ietf.org/doc/html/rfc938)\] \[Trudy_Miller\]
    pub const IRTP: IpNumber = Self(28);
    /// ISO Transport Protocol Class 4 \[[RFC905](https://datatracker.ietf.org/doc/html/rfc905)\] \[mystery contact\]
    pub const ISO_TP4: IpNumber = Self(29);
    /// Bulk Data Transfer Protocol \[[RFC969](https://datatracker.ietf.org/doc/html/rfc969)\] \[David_Clark\]
    pub const NET_BLT: IpNumber = Self(30);
    /// MFE Network Services Protocol \[Shuttleworth, B., "A Documentary of MFENet, a National Computer Network", UCRL-52317, Lawrence Livermore Labs, Livermore, California, June 1977.\] \[Barry_Howard\]
    pub const MFE_NSP: IpNumber = Self(31);
    /// MERIT Internodal Protocol \[Hans_Werner_Braun\]
    pub const MERIT_INP: IpNumber = Self(32);
    /// Datagram Congestion Control Protocol \[[RFC4340](https://datatracker.ietf.org/doc/html/rfc4340)\]
    pub const DCCP: IpNumber = Self(33);
    /// Third Party Connect Protocol \[Stuart_A_Friedberg\]
    pub const THIRD_PARTY_CONNECT_PROTOCOL: IpNumber = Self(34);
    /// Inter-Domain Policy Routing Protocol \[Martha_Steenstrup\]
    pub const IDPR: IpNumber = Self(35);
    /// XTP \[Greg_Chesson\]
    pub const XTP: IpNumber = Self(36);
    /// Datagram Delivery Protocol \[Wesley_Craig\]
    pub const DDP: IpNumber = Self(37);
    /// IDPR Control Message Transport Proto \[Martha_Steenstrup\]
    pub const IDPR_CMTP: IpNumber = Self(38);
    /// TP++ Transport Protocol \[Dirk_Fromhein\]
    pub const TP_PLUS_PLUS: IpNumber = Self(39);
    /// IL Transport Protocol \[Dave_Presotto\]
    pub const IL: IpNumber = Self(40);
    /// IPv6 encapsulation \[[RFC2473](https://datatracker.ietf.org/doc/html/rfc2473)\]
    pub const IPV6: IpNumber = Self(41);
    /// Source Demand Routing Protocol \[Deborah_Estrin\]
    pub const SDRP: IpNumber = Self(42);
    /// Routing Header for IPv6 \[Steve_Deering\]
    pub const IPV6_ROUTE_HEADER: IpNumber = Self(43);
    /// Fragment Header for IPv6 \[Steve_Deering\]
    pub const IPV6_FRAGMENTATION_HEADER: IpNumber = Self(44);
    /// Inter-Domain Routing Protocol \[Sue_Hares\]
    pub const IDRP: IpNumber = Self(45);
    /// Reservation Protocol \[[RFC2205](https://datatracker.ietf.org/doc/html/rfc2205)\]\[[RFC3209](https://datatracker.ietf.org/doc/html/rfc3209)\]\[Bob_Braden\]
    pub const RSVP: IpNumber = Self(46);
    /// Generic Routing Encapsulation \[[RFC2784](https://datatracker.ietf.org/doc/html/rfc2784)\]\[Tony_Li\]
    pub const GRE: IpNumber = Self(47);
    /// Dynamic Source Routing Protocol \[[RFC4728](https://datatracker.ietf.org/doc/html/rfc4728)\]
    pub const DSR: IpNumber = Self(48);
    /// BNA \[Gary Salamon\]
    pub const BNA: IpNumber = Self(49);
    /// Encapsulating Security Payload \[[RFC4303](https://datatracker.ietf.org/doc/html/rfc4303)\]
    pub const ENCAPSULATING_SECURITY_PAYLOAD: IpNumber = Self(50);
    /// Authentication Header \[[RFC4302](https://datatracker.ietf.org/doc/html/rfc4302)\]
    pub const AUTHENTICATION_HEADER: IpNumber = Self(51);
    /// Integrated Net Layer Security  TUBA \[K_Robert_Glenn\]
    pub const INLSP: IpNumber = Self(52);
    /// IP with Encryption (deprecated) \[John_Ioannidis\]
    pub const SWIPE: IpNumber = Self(53);
    /// NBMA Address Resolution Protocol \[[RFC1735](https://datatracker.ietf.org/doc/html/rfc1735)\]
    pub const NARP: IpNumber = Self(54);
    /// IP Mobility \[Charlie_Perkins\]
    pub const MOBILE: IpNumber = Self(55);
    /// Transport Layer Security Protocol using Kryptonet key management \[Christer_Oberg\]
    pub const TLSP: IpNumber = Self(56);
    /// SKIP \[Tom_Markson\]
    pub const SKIP: IpNumber = Self(57);
    /// ICMP for IPv6 \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    pub const IPV6_ICMP: IpNumber = Self(58);
    /// No Next Header for IPv6 \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    pub const IPV6_NO_NEXT_HEADER: IpNumber = Self(59);
    /// Destination Options for IPv6 \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    pub const IPV6_DESTINATION_OPTIONS: IpNumber = Self(60);
    /// any host internal protocol \[Internet_Assigned_Numbers_Authority\]
    pub const ANY_HOST_INTERNAL_PROTOCOL: IpNumber = Self(61);
    /// CFTP \[Forsdick, H., "CFTP", Network Message, Bolt Beranek and Newman, January 1982.\]\[Harry_Forsdick\]
    pub const CFTP: IpNumber = Self(62);
    /// any local network \[Internet_Assigned_Numbers_Authority\]
    pub const ANY_LOCAL_NETWORK: IpNumber = Self(63);
    /// SATNET and Backroom EXPAK \[Steven_Blumenthal\]
    pub const SAT_EXPAK: IpNumber = Self(64);
    /// Kryptolan \[Paul Liu\]
    pub const KRYTOLAN: IpNumber = Self(65);
    /// MIT Remote Virtual Disk Protocol \[Michael_Greenwald\]
    pub const RVD: IpNumber = Self(66);
    /// Internet Pluribus Packet Core \[Steven_Blumenthal\]
    pub const IPPC: IpNumber = Self(67);
    /// any distributed file system \[Internet_Assigned_Numbers_Authority\]
    pub const ANY_DISTRIBUTED_FILE_SYSTEM: IpNumber = Self(68);
    /// SATNET Monitoring \[Steven_Blumenthal\]
    pub const SAT_MON: IpNumber = Self(69);
    /// VISA Protocol \[Gene_Tsudik\]
    pub const VISA: IpNumber = Self(70);
    /// Internet Packet Core Utility \[Steven_Blumenthal\]
    pub const IPCV: IpNumber = Self(71);
    /// Computer Protocol Network Executive \[David Mittnacht\]
    pub const CPNX: IpNumber = Self(72);
    /// Computer Protocol Heart Beat \[David Mittnacht\]
    pub const CPHB: IpNumber = Self(73);
    /// Wang Span Network \[Victor Dafoulas\]
    pub const WSN: IpNumber = Self(74);
    /// Packet Video Protocol \[Steve_Casner\]
    pub const PVP: IpNumber = Self(75);
    /// Backroom SATNET Monitoring \[Steven_Blumenthal\]
    pub const BR_SAT_MON: IpNumber = Self(76);
    /// SUN ND PROTOCOL-Temporary \[William_Melohn\]
    pub const SUN_ND: IpNumber = Self(77);
    /// WIDEBAND Monitoring \[Steven_Blumenthal\]
    pub const WB_MON: IpNumber = Self(78);
    /// WIDEBAND EXPAK \[Steven_Blumenthal\]
    pub const WB_EXPAK: IpNumber = Self(79);
    /// ISO Internet Protocol \[Marshall_T_Rose\]
    pub const ISO_IP: IpNumber = Self(80);
    /// VMTP \[Dave_Cheriton\]
    pub const VMTP: IpNumber = Self(81);
    /// SECURE-VMTP \[Dave_Cheriton\]
    pub const SECURE_VMTP: IpNumber = Self(82);
    /// VINES \[Brian Horn\]
    pub const VINES: IpNumber = Self(83);
    /// Transaction Transport Protocol or Internet Protocol Traffic Manager \[Jim_Stevens\]
    pub const TTP_OR_IPTM: IpNumber = Self(84);
    /// NSFNET-IGP \[Hans_Werner_Braun\]
    pub const NSFNET_IGP: IpNumber = Self(85);
    /// Dissimilar Gateway Protocol \[M/A-COM Government Systems, "Dissimilar Gateway Protocol Specification, Draft Version", Contract no. CS901145, November 16, 1987.\]\[Mike_Little\]
    pub const DGP: IpNumber = Self(86);
    /// TCF \[Guillermo_A_Loyola\]
    pub const TCF: IpNumber = Self(87);
    /// EIGRP \[[RFC7868](https://datatracker.ietf.org/doc/html/rfc7868)\]
    pub const EIGRP: IpNumber = Self(88);
    /// OSPFIGP \[[RFC1583](https://datatracker.ietf.org/doc/html/rfc1583)\]\[[RFC2328](https://datatracker.ietf.org/doc/html/rfc2328)\]\[[RFC5340](https://datatracker.ietf.org/doc/html/rfc5340)\]\[John_Moy\]
    pub const OSPFIGP: IpNumber = Self(89);
    /// Sprite RPC Protocol \[Welch, B., "The Sprite Remote Procedure Call System", Technical Report, UCB/Computer Science Dept., 86/302, University of California at Berkeley, June 1986.\]\[Bruce Willins\]
    pub const SPRITE_RPC: IpNumber = Self(90);
    /// Locus Address Resolution Protocol \[Brian Horn\]
    pub const LARP: IpNumber = Self(91);
    /// Multicast Transport Protocol \[Susie_Armstrong\]
    pub const MTP: IpNumber = Self(92);
    /// AX.25 Frames \[Brian_Kantor\]
    pub const AX25: IpNumber = Self(93);
    /// IP-within-IP Encapsulation Protocol \[John_Ioannidis\]
    pub const IPIP: IpNumber = Self(94);
    /// Mobile Internetworking Control Pro. (deprecated) \[John_Ioannidis\]
    pub const MICP: IpNumber = Self(95);
    /// Semaphore Communications Sec. Pro. \[Howard_Hart\]
    pub const SCC_SP: IpNumber = Self(96);
    /// Ethernet-within-IP Encapsulation \[[RFC3378](https://datatracker.ietf.org/doc/html/rfc3378)\]
    pub const ETHER_IP: IpNumber = Self(97);
    /// Encapsulation Header \[[RFC1241](https://datatracker.ietf.org/doc/html/rfc1241)\]\[Robert_Woodburn\]
    pub const ENCAP: IpNumber = Self(98);
    /// GMTP \[\[RXB5\]\]
    pub const GMTP: IpNumber = Self(100);
    /// Ipsilon Flow Management Protocol \[Bob_Hinden\]\[November 1995, 1997.\]
    pub const IFMP: IpNumber = Self(101);
    /// PNNI over IP \[Ross_Callon\]
    pub const PNNI: IpNumber = Self(102);
    /// Protocol Independent Multicast \[[RFC7761](https://datatracker.ietf.org/doc/html/rfc7761)\]\[Dino_Farinacci\]
    pub const PIM: IpNumber = Self(103);
    /// ARIS \[Nancy_Feldman\]
    pub const ARIS: IpNumber = Self(104);
    /// SCPS \[Robert_Durst\]
    pub const SCPS: IpNumber = Self(105);
    /// QNX \[Michael_Hunter\]
    pub const QNX: IpNumber = Self(106);
    /// Active Networks \[Bob_Braden\]
    pub const ACTIVE_NETWORKS: IpNumber = Self(107);
    /// IP Payload Compression Protocol \[[RFC2393](https://datatracker.ietf.org/doc/html/rfc2393)\]
    pub const IP_COMP: IpNumber = Self(108);
    /// Sitara Networks Protocol \[Manickam_R_Sridhar\]
    pub const SITRA_NETWORKS_PROTOCOL: IpNumber = Self(109);
    /// Compaq Peer Protocol \[Victor_Volpe\]
    pub const COMPAQ_PEER: IpNumber = Self(110);
    /// IPX in IP \[CJ_Lee\]
    pub const IPX_IN_IP: IpNumber = Self(111);
    /// Virtual Router Redundancy Protocol \[[RFC5798](https://datatracker.ietf.org/doc/html/rfc5798)\]
    pub const VRRP: IpNumber = Self(112);
    /// PGM Reliable Transport Protocol \[Tony_Speakman\]
    pub const PGM: IpNumber = Self(113);
    /// any 0-hop protocol \[Internet_Assigned_Numbers_Authority\]
    pub const ANY_ZERO_HOP_PROTOCOL: IpNumber = Self(114);
    /// Layer Two Tunneling Protocol \[[RFC3931](https://datatracker.ietf.org/doc/html/rfc3931)\]\[Bernard_Aboba\]
    pub const LAYER2_TUNNELING_PROTOCOL: IpNumber = Self(115);
    /// D-II Data Exchange (DDX) \[John_Worley\]
    pub const DDX: IpNumber = Self(116);
    /// Interactive Agent Transfer Protocol \[John_Murphy\]
    pub const IATP: IpNumber = Self(117);
    /// Schedule Transfer Protocol \[Jean_Michel_Pittet\]
    pub const STP: IpNumber = Self(118);
    /// SpectraLink Radio Protocol \[Mark_Hamilton\]
    pub const SRP: IpNumber = Self(119);
    /// UTI \[Peter_Lothberg\]
    pub const UTI: IpNumber = Self(120);
    /// Simple Message Protocol \[Leif_Ekblad\]
    pub const SIMPLE_MESSAGE_PROTOCOL: IpNumber = Self(121);
    /// Simple Multicast Protocol (deprecated) \[Jon_Crowcroft\]\[draft-perlman-simple-multicast\]
    pub const SM: IpNumber = Self(122);
    /// Performance Transparency Protocol \[Michael_Welzl\]
    pub const PTP: IpNumber = Self(123);
    /// ISIS over IPv4 \[Tony_Przygienda\]
    pub const ISIS_OVER_IPV4: IpNumber = Self(124);
    /// FIRE \[Criag_Partridge\]
    pub const FIRE: IpNumber = Self(125);
    /// Combat Radio Transport Protocol \[Robert_Sautter\]
    pub const CRTP: IpNumber = Self(126);
    /// Combat Radio User Datagram \[Robert_Sautter\]
    pub const CRUDP: IpNumber = Self(127);
    /// SSCOPMCE \[Kurt_Waber\]
    pub const SSCOPMCE: IpNumber = Self(128);
    /// IPLT \[\[Hollbach\]\]
    pub const IPLT: IpNumber = Self(129);
    /// Secure Packet Shield \[Bill_McIntosh\]
    pub const SPS: IpNumber = Self(130);
    /// Private IP Encapsulation within IP \[Bernhard_Petri\]
    pub const PIPE: IpNumber = Self(131);
    /// Stream Control Transmission Protocol \[Randall_R_Stewart\]
    pub const SCTP: IpNumber = Self(132);
    /// Fibre Channel \[Murali_Rajagopal\]\[[RFC6172](https://datatracker.ietf.org/doc/html/rfc6172)\]
    pub const FC: IpNumber = Self(133);
    /// RSVP-E2E-IGNORE \[[RFC3175](https://datatracker.ietf.org/doc/html/rfc3175)\]
    pub const RSVP_E2E_IGNORE: IpNumber = Self(134);
    /// MobilityHeader \[[RFC6275](https://datatracker.ietf.org/doc/html/rfc6275)\]
    pub const MOBILITY_HEADER: IpNumber = Self(135);
    /// UDPLite \[[RFC3828](https://datatracker.ietf.org/doc/html/rfc3828)\]
    pub const UDP_LITE: IpNumber = Self(136);
    /// \[[RFC4023](https://datatracker.ietf.org/doc/html/rfc4023)\]
    pub const MPLS_IN_IP: IpNumber = Self(137);
    /// MANET Protocols \[[RFC5498](https://datatracker.ietf.org/doc/html/rfc5498)\]
    pub const MANET: IpNumber = Self(138);
    /// Host Identity Protocol \[[RFC7401](https://datatracker.ietf.org/doc/html/rfc7401)\]
    pub const HIP: IpNumber = Self(139);
    /// Shim6 Protocol \[[RFC5533](https://datatracker.ietf.org/doc/html/rfc5533)\]
    pub const SHIM6: IpNumber = Self(140);
    /// Wrapped Encapsulating Security Payload \[[RFC5840](https://datatracker.ietf.org/doc/html/rfc5840)\]
    pub const WESP: IpNumber = Self(141);
    /// Robust Header Compression \[[RFC5858](https://datatracker.ietf.org/doc/html/rfc5858)\]
    pub const ROHC: IpNumber = Self(142);
    /// Use for experimentation and testing
    pub const EXPERIMENTAL_AND_TESTING_0: IpNumber = Self(253);
    /// Use for experimentation and testing
    pub const EXPERIMENTAL_AND_TESTING_1: IpNumber = Self(254);
}

impl IpNumber {
    /// Returns true if the given number is the internet number of an IPV6 extension header.
    pub fn is_ipv6_ext_header_value(self) -> bool {
        use crate::ip_number::*;
        matches!(
            self,
            IPV6_HOP_BY_HOP
                | IPV6_ROUTE
                | IPV6_FRAG
                | ENCAP_SEC
                | AUTH
                | IPV6_DEST_OPTIONS
                | MOBILITY
                | HIP
                | SHIM6
                | EXP0
                | EXP1
        )
    }

    /// Returns the "keyword" string if known. Usually this is the abbreviation of the protocol.
    ///
    /// # Example
    ///
    /// ```
    /// use etherparse::IpNumber;
    ///
    /// assert_eq!(IpNumber::UDP.keyword_str(), Some("UDP"));
    ///
    /// // Unassigned values return None
    /// assert_eq!(IpNumber(145).keyword_str(), None);
    /// ```
    ///
    /// # Data Source
    ///
    /// The strings were copied from <https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml>
    /// on 2023-04-11.
    pub fn keyword_str(self) -> Option<&'static str> {
        // auto generated from CSV
        // https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
        // on 2023-04-11.
        match self.0 {
            0 => Some("HOPOPT"),
            1 => Some("ICMP"),
            2 => Some("IGMP"),
            3 => Some("GGP"),
            4 => Some("IPv4"),
            5 => Some("ST"),
            6 => Some("TCP"),
            7 => Some("CBT"),
            8 => Some("EGP"),
            9 => Some("IGP"),
            10 => Some("BBN-RCC-MON"),
            11 => Some("NVP-II"),
            12 => Some("PUP"),
            13 => Some("ARGUS (deprecated)"),
            14 => Some("EMCON"),
            15 => Some("XNET"),
            16 => Some("CHAOS"),
            17 => Some("UDP"),
            18 => Some("MUX"),
            19 => Some("DCN-MEAS"),
            20 => Some("HMP"),
            21 => Some("PRM"),
            22 => Some("XNS-IDP"),
            23 => Some("TRUNK-1"),
            24 => Some("TRUNK-2"),
            25 => Some("LEAF-1"),
            26 => Some("LEAF-2"),
            27 => Some("RDP"),
            28 => Some("IRTP"),
            29 => Some("ISO-TP4"),
            30 => Some("NETBLT"),
            31 => Some("MFE-NSP"),
            32 => Some("MERIT-INP"),
            33 => Some("DCCP"),
            34 => Some("3PC"),
            35 => Some("IDPR"),
            36 => Some("XTP"),
            37 => Some("DDP"),
            38 => Some("IDPR-CMTP"),
            39 => Some("TP++"),
            40 => Some("IL"),
            41 => Some("IPv6"),
            42 => Some("SDRP"),
            43 => Some("IPv6-Route"),
            44 => Some("IPv6-Frag"),
            45 => Some("IDRP"),
            46 => Some("RSVP"),
            47 => Some("GRE"),
            48 => Some("DSR"),
            49 => Some("BNA"),
            50 => Some("ESP"),
            51 => Some("AH"),
            52 => Some("I-NLSP"),
            53 => Some("SWIPE (deprecated)"),
            54 => Some("NARP"),
            55 => Some("MOBILE"),
            56 => Some("TLSP"),
            57 => Some("SKIP"),
            58 => Some("IPv6-ICMP"),
            59 => Some("IPv6-NoNxt"),
            60 => Some("IPv6-Opts"),
            61 => None,
            62 => Some("CFTP"),
            63 => None,
            64 => Some("SAT-EXPAK"),
            65 => Some("KRYPTOLAN"),
            66 => Some("RVD"),
            67 => Some("IPPC"),
            68 => None,
            69 => Some("SAT-MON"),
            70 => Some("VISA"),
            71 => Some("IPCV"),
            72 => Some("CPNX"),
            73 => Some("CPHB"),
            74 => Some("WSN"),
            75 => Some("PVP"),
            76 => Some("BR-SAT-MON"),
            77 => Some("SUN-ND"),
            78 => Some("WB-MON"),
            79 => Some("WB-EXPAK"),
            80 => Some("ISO-IP"),
            81 => Some("VMTP"),
            82 => Some("SECURE-VMTP"),
            83 => Some("VINES"),
            84 => Some("IPTM"),
            85 => Some("NSFNET-IGP"),
            86 => Some("DGP"),
            87 => Some("TCF"),
            88 => Some("EIGRP"),
            89 => Some("OSPFIGP"),
            90 => Some("Sprite-RPC"),
            91 => Some("LARP"),
            92 => Some("MTP"),
            93 => Some("AX.25"),
            94 => Some("IPIP"),
            95 => Some("MICP (deprecated)"),
            96 => Some("SCC-SP"),
            97 => Some("ETHERIP"),
            98 => Some("ENCAP"),
            99 => None,
            100 => Some("GMTP"),
            101 => Some("IFMP"),
            102 => Some("PNNI"),
            103 => Some("PIM"),
            104 => Some("ARIS"),
            105 => Some("SCPS"),
            106 => Some("QNX"),
            107 => Some("A/N"),
            108 => Some("IPComp"),
            109 => Some("SNP"),
            110 => Some("Compaq-Peer"),
            111 => Some("IPX-in-IP"),
            112 => Some("VRRP"),
            113 => Some("PGM"),
            114 => None,
            115 => Some("L2TP"),
            116 => Some("DDX"),
            117 => Some("IATP"),
            118 => Some("STP"),
            119 => Some("SRP"),
            120 => Some("UTI"),
            121 => Some("SMP"),
            122 => Some("SM (deprecated)"),
            123 => Some("PTP"),
            124 => Some("ISIS over IPv4"),
            125 => Some("FIRE"),
            126 => Some("CRTP"),
            127 => Some("CRUDP"),
            128 => Some("SSCOPMCE"),
            129 => Some("IPLT"),
            130 => Some("SPS"),
            131 => Some("PIPE"),
            132 => Some("SCTP"),
            133 => Some("FC"),
            134 => Some("RSVP-E2E-IGNORE"),
            135 => Some("Mobility Header"),
            136 => Some("UDPLite"),
            137 => Some("MPLS-in-IP"),
            138 => Some("manet"),
            139 => Some("HIP"),
            140 => Some("Shim6"),
            141 => Some("WESP"),
            142 => Some("ROHC"),
            143 => Some("Ethernet"),
            144 => Some("AGGFRAG"),
            145..=252 => None,
            253 => None,
            254 => None,
            255 => Some("Reserved"),
        }
    }

    /// Returns the "protocol" string if known. Usually this the non abbreviated name of the protocol.
    ///
    /// # Example
    ///
    /// ```
    /// use etherparse::IpNumber;
    ///
    /// assert_eq!(IpNumber::UDP.protocol_str(), Some("User Datagram"));
    ///
    /// // Unassigned values return None
    /// assert_eq!(IpNumber(145).protocol_str(), None);
    /// ```
    ///
    /// # Data Source
    ///
    /// The string was copied from <https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml>
    /// on 2023-04-11.
    pub fn protocol_str(self) -> Option<&'static str> {
        // auto generated from CSV
        // https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
        // on 2023-04-11.
        match self.0 {
            0 => Some("IPv6 Hop-by-Hop Option"),
            1 => Some("Internet Control Message"),
            2 => Some("Internet Group Management"),
            3 => Some("Gateway-to-Gateway"),
            4 => Some("IPv4 encapsulation"),
            5 => Some("Stream"),
            6 => Some("Transmission Control"),
            7 => Some("CBT"),
            8 => Some("Exterior Gateway Protocol"),
            9 => Some("any private interior gateway (used by Cisco for their IGRP)"),
            10 => Some("BBN RCC Monitoring"),
            11 => Some("Network Voice Protocol"),
            12 => Some("PUP"),
            13 => Some("ARGUS"),
            14 => Some("EMCON"),
            15 => Some("Cross Net Debugger"),
            16 => Some("Chaos"),
            17 => Some("User Datagram"),
            18 => Some("Multiplexing"),
            19 => Some("DCN Measurement Subsystems"),
            20 => Some("Host Monitoring"),
            21 => Some("Packet Radio Measurement"),
            22 => Some("XEROX NS IDP"),
            23 => Some("Trunk-1"),
            24 => Some("Trunk-2"),
            25 => Some("Leaf-1"),
            26 => Some("Leaf-2"),
            27 => Some("Reliable Data Protocol"),
            28 => Some("Internet Reliable Transaction"),
            29 => Some("ISO Transport Protocol Class 4"),
            30 => Some("Bulk Data Transfer Protocol"),
            31 => Some("MFE Network Services Protocol"),
            32 => Some("MERIT Internodal Protocol"),
            33 => Some("Datagram Congestion Control Protocol"),
            34 => Some("Third Party Connect Protocol"),
            35 => Some("Inter-Domain Policy Routing Protocol"),
            36 => Some("XTP"),
            37 => Some("Datagram Delivery Protocol"),
            38 => Some("IDPR Control Message Transport Proto"),
            39 => Some("TP++ Transport Protocol"),
            40 => Some("IL Transport Protocol"),
            41 => Some("IPv6 encapsulation"),
            42 => Some("Source Demand Routing Protocol"),
            43 => Some("Routing Header for IPv6"),
            44 => Some("Fragment Header for IPv6"),
            45 => Some("Inter-Domain Routing Protocol"),
            46 => Some("Reservation Protocol"),
            47 => Some("Generic Routing Encapsulation"),
            48 => Some("Dynamic Source Routing Protocol"),
            49 => Some("BNA"),
            50 => Some("Encap Security Payload"),
            51 => Some("Authentication Header"),
            52 => Some("Integrated Net Layer Security  TUBA"),
            53 => Some("IP with Encryption"),
            54 => Some("NBMA Address Resolution Protocol"),
            55 => Some("IP Mobility"),
            56 => Some("Transport Layer Security Protocol using Kryptonet key management"),
            57 => Some("SKIP"),
            58 => Some("ICMP for IPv6"),
            59 => Some("No Next Header for IPv6"),
            60 => Some("Destination Options for IPv6"),
            61 => Some("any host internal protocol"),
            62 => Some("CFTP"),
            63 => Some("any local network"),
            64 => Some("SATNET and Backroom EXPAK"),
            65 => Some("Kryptolan"),
            66 => Some("MIT Remote Virtual Disk Protocol"),
            67 => Some("Internet Pluribus Packet Core"),
            68 => Some("any distributed file system"),
            69 => Some("SATNET Monitoring"),
            70 => Some("VISA Protocol"),
            71 => Some("Internet Packet Core Utility"),
            72 => Some("Computer Protocol Network Executive"),
            73 => Some("Computer Protocol Heart Beat"),
            74 => Some("Wang Span Network"),
            75 => Some("Packet Video Protocol"),
            76 => Some("Backroom SATNET Monitoring"),
            77 => Some("SUN ND PROTOCOL-Temporary"),
            78 => Some("WIDEBAND Monitoring"),
            79 => Some("WIDEBAND EXPAK"),
            80 => Some("ISO Internet Protocol"),
            81 => Some("VMTP"),
            82 => Some("SECURE-VMTP"),
            83 => Some("VINES"),
            84 => Some("Internet Protocol Traffic Manager"),
            85 => Some("NSFNET-IGP"),
            86 => Some("Dissimilar Gateway Protocol"),
            87 => Some("TCF"),
            88 => Some("EIGRP"),
            89 => Some("OSPFIGP"),
            90 => Some("Sprite RPC Protocol"),
            91 => Some("Locus Address Resolution Protocol"),
            92 => Some("Multicast Transport Protocol"),
            93 => Some("AX.25 Frames"),
            94 => Some("IP-within-IP Encapsulation Protocol"),
            95 => Some("Mobile Internetworking Control Pro."),
            96 => Some("Semaphore Communications Sec. Pro."),
            97 => Some("Ethernet-within-IP Encapsulation"),
            98 => Some("Encapsulation Header"),
            99 => Some("any private encryption scheme"),
            100 => Some("GMTP"),
            101 => Some("Ipsilon Flow Management Protocol"),
            102 => Some("PNNI over IP"),
            103 => Some("Protocol Independent Multicast"),
            104 => Some("ARIS"),
            105 => Some("SCPS"),
            106 => Some("QNX"),
            107 => Some("Active Networks"),
            108 => Some("IP Payload Compression Protocol"),
            109 => Some("Sitara Networks Protocol"),
            110 => Some("Compaq Peer Protocol"),
            111 => Some("IPX in IP"),
            112 => Some("Virtual Router Redundancy Protocol"),
            113 => Some("PGM Reliable Transport Protocol"),
            114 => Some("any 0-hop protocol"),
            115 => Some("Layer Two Tunneling Protocol"),
            116 => Some("D-II Data Exchange (DDX)"),
            117 => Some("Interactive Agent Transfer Protocol"),
            118 => Some("Schedule Transfer Protocol"),
            119 => Some("SpectraLink Radio Protocol"),
            120 => Some("UTI"),
            121 => Some("Simple Message Protocol"),
            122 => Some("Simple Multicast Protocol"),
            123 => Some("Performance Transparency Protocol"),
            124 => None,
            125 => None,
            126 => Some("Combat Radio Transport Protocol"),
            127 => Some("Combat Radio User Datagram"),
            128 => None,
            129 => None,
            130 => Some("Secure Packet Shield"),
            131 => Some("Private IP Encapsulation within IP"),
            132 => Some("Stream Control Transmission Protocol"),
            133 => Some("Fibre Channel"),
            134 => None,
            135 => None,
            136 => None,
            137 => None,
            138 => Some("MANET Protocols"),
            139 => Some("Host Identity Protocol"),
            140 => Some("Shim6 Protocol"),
            141 => Some("Wrapped Encapsulating Security Payload"),
            142 => Some("Robust Header Compression"),
            143 => Some("Ethernet"),
            144 => Some("AGGFRAG encapsulation payload for ESP"),
            145..=252 => None,
            253 => Some("Use for experimentation and testing"),
            254 => Some("Use for experimentation and testing"),
            255 => None,
        }
    }
}

impl Default for IpNumber {
    #[inline]
    fn default() -> Self {
        // 255 chosen as it is not used by any
        // protocol and is reserved.
        Self(255)
    }
}

impl From<u8> for IpNumber {
    #[inline]
    fn from(val: u8) -> Self {
        Self(val)
    }
}

impl From<IpNumber> for u8 {
    #[inline]
    fn from(val: IpNumber) -> Self {
        val.0
    }
}

impl core::fmt::Debug for IpNumber {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        if let Some(keyword) = self.keyword_str() {
            if let Some(protocol) = self.protocol_str() {
                write!(f, "{} ({} - {})", self.0, keyword, protocol)
            } else {
                write!(f, "{} ({})", self.0, keyword)
            }
        } else if let Some(protocol) = self.protocol_str() {
            write!(f, "{} ({})", self.0, protocol)
        } else {
            write!(f, "{}", self.0)
        }
    }
}

/// Constants for the ip protocol numbers for easy importing (e.g. `use ip_number::*;`).
///
/// The constants only exist for convenience so you can import them
/// (`use ip_number::*`) without a need to write `IpNumber::` in front
/// of every constant.
///
/// You can access the underlying `u8` value by using `.0` and any `u8`
/// can be converted to an `IpNumber`:
///
/// ```
/// use etherparse::{ip_number::TCP, IpNumber};
///
/// assert_eq!(TCP.0, 6);
/// assert_eq!(TCP, IpNumber(6));
/// let num: IpNumber = 6.into();
/// assert_eq!(TCP, num);
/// ```
///
/// The list original values were copied from
/// <https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml>
pub mod ip_number {
    use crate::IpNumber;

    /// IPv6 Hop-by-Hop Option \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    pub const IPV6_HOP_BY_HOP: IpNumber = IpNumber::IPV6_HEADER_HOP_BY_HOP; // 0
    /// IPv6 Hop-by-Hop Option \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    pub const IPV6_HEADER_HOP_BY_HOP: IpNumber = IpNumber::IPV6_HEADER_HOP_BY_HOP; // 0
    /// Internet Control Message \[[RFC792](https://datatracker.ietf.org/doc/html/rfc792)\]
    pub const ICMP: IpNumber = IpNumber::ICMP; // 1
    /// Internet Group Management \[[RFC1112](https://datatracker.ietf.org/doc/html/rfc1112)\]
    pub const IGMP: IpNumber = IpNumber::IGMP; // 2
    /// Gateway-to-Gateway \[[RFC823](https://datatracker.ietf.org/doc/html/rfc823)\]
    pub const GGP: IpNumber = IpNumber::GGP; // 3
    /// IPv4 encapsulation \[[RFC2003](https://datatracker.ietf.org/doc/html/rfc2003)\]
    pub const IPV4: IpNumber = IpNumber::IPV4; // 4
    /// Stream \[[RFC1190](https://datatracker.ietf.org/doc/html/rfc1190)\] \[[RFC1819](https://datatracker.ietf.org/doc/html/rfc1819)\]
    pub const STREAM: IpNumber = IpNumber::STREAM; // 5
    /// Transmission Control \[[RFC793](https://datatracker.ietf.org/doc/html/rfc793)\]
    pub const TCP: IpNumber = IpNumber::TCP; // 6
    /// CBT \[Tony_Ballardie\]
    pub const CBT: IpNumber = IpNumber::CBT; // 7
    /// Exterior Gateway Protocol \[[RFC888](https://datatracker.ietf.org/doc/html/rfc888)\] \[David_Mills\]
    pub const EGP: IpNumber = IpNumber::EGP; // 8
    /// any private interior gateway (used by Cisco for their IGRP) \[Internet_Assigned_Numbers_Authority\]
    pub const IGP: IpNumber = IpNumber::IGP; // 9
    /// BBN RCC Monitoring \[Steve_Chipman\]
    pub const BBN_RCC_MON: IpNumber = IpNumber::BBN_RCC_MON; // 10
    /// Network Voice Protocol \[[RFC741](https://datatracker.ietf.org/doc/html/rfc741)\]\[Steve_Casner\]
    pub const NVP_II: IpNumber = IpNumber::NVP_II; // 11
    /// PUP
    pub const PUP: IpNumber = IpNumber::PUP; // 12
    /// ARGUS (deprecated) \[Robert_W_Scheifler\]
    pub const ARGUS: IpNumber = IpNumber::ARGUS; // 13
    /// EMCON \[mystery contact\]
    pub const EMCON: IpNumber = IpNumber::EMCON; // 14
    /// Cross Net Debugger \[Haverty, J., "XNET Formats for Internet Protocol Version 4", IEN 158, October 1980.\]\[Jack_Haverty\]
    pub const XNET: IpNumber = IpNumber::XNET; // 15
    /// Chaos \[J_Noel_Chiappa\]
    pub const CHAOS: IpNumber = IpNumber::CHAOS; // 16
    /// User Datagram \[[RFC768](https://datatracker.ietf.org/doc/html/rfc768)\] \[Jon_Postel\]
    pub const UDP: IpNumber = IpNumber::UDP; // 17
    /// Multiplexing \[Cohen, D. and J. Postel, "Multiplexing Protocol", IEN 90, USC/Information Sciences Institute, May 1979.\]\[Jon_Postel\]
    pub const MUX: IpNumber = IpNumber::MUX; // 18
    /// DCN Measurement Subsystems \[David_Mills\]
    pub const DCN_MEAS: IpNumber = IpNumber::DCN_MEAS; // 19
    /// Host Monitoring \[[RFC869](https://datatracker.ietf.org/doc/html/rfc869)\]\[Bob_Hinden\]
    pub const HMP: IpNumber = IpNumber::HMP; // 20
    /// Packet Radio Measurement \[Zaw_Sing_Su\]
    pub const PRM: IpNumber = IpNumber::PRM; // 21
    /// XEROX NS IDP
    pub const XNS_IDP: IpNumber = IpNumber::XNS_IDP; // 22
    /// Trunk-1 \[Barry_Boehm\]
    pub const TRUNK1: IpNumber = IpNumber::TRUNK1; // 23
    /// Trunk-2 \[Barry_Boehm\]
    pub const TRUNK2: IpNumber = IpNumber::TRUNK2; // 24
    /// Leaf-1 \[Barry_Boehm\]
    pub const LEAF1: IpNumber = IpNumber::LEAF1; // 25
    /// Leaf-2 \[Barry_Boehm\]
    pub const LEAF2: IpNumber = IpNumber::LEAF2; // 26
    /// Reliable Data Protocol \[[RFC908](https://datatracker.ietf.org/doc/html/rfc908)\] \[Bob_Hinden\]
    pub const RDP: IpNumber = IpNumber::RDP; // 27
    /// Internet Reliable Transaction \[[RFC938](https://datatracker.ietf.org/doc/html/rfc938)\] \[Trudy_Miller\]
    pub const IRTP: IpNumber = IpNumber::IRTP; // 28
    /// ISO Transport Protocol Class 4 \[[RFC905](https://datatracker.ietf.org/doc/html/rfc905)\] \[mystery contact\]
    pub const ISO_TP4: IpNumber = IpNumber::ISO_TP4; // 29
    /// Bulk Data Transfer Protocol \[[RFC969](https://datatracker.ietf.org/doc/html/rfc969)\] \[David_Clark\]
    pub const NET_BLT: IpNumber = IpNumber::NET_BLT; // 30
    /// MFE Network Services Protocol \[Shuttleworth, B., "A Documentary of MFENet, a National Computer Network", UCRL-52317, Lawrence Livermore Labs, Livermore, California, June 1977.\] \[Barry_Howard\]
    pub const MFE_NSP: IpNumber = IpNumber::MFE_NSP; // 31
    /// MERIT Internodal Protocol \[Hans_Werner_Braun\]
    pub const MERIT_INP: IpNumber = IpNumber::MERIT_INP; // 32
    /// Datagram Congestion Control Protocol \[[RFC4340](https://datatracker.ietf.org/doc/html/rfc4340)\]
    pub const DCCP: IpNumber = IpNumber::DCCP; // 33
    /// Third Party Connect Protocol \[Stuart_A_Friedberg\]
    pub const THIRD_PARTY_CONNECT_PROTOCOL: IpNumber = IpNumber::THIRD_PARTY_CONNECT_PROTOCOL; // 34
    /// Inter-Domain Policy Routing Protocol \[Martha_Steenstrup\]
    pub const IDPR: IpNumber = IpNumber::IDPR; // 35
    /// XTP \[Greg_Chesson\]
    pub const XTP: IpNumber = IpNumber::XTP; // 36
    /// Datagram Delivery Protocol \[Wesley_Craig\]
    pub const DDP: IpNumber = IpNumber::DDP; // 37
    /// IDPR Control Message Transport Proto \[Martha_Steenstrup\]
    pub const IDPR_CMTP: IpNumber = IpNumber::IDPR_CMTP; // 38
    /// TP++ Transport Protocol \[Dirk_Fromhein\]
    pub const TP_PLUS_PLUS: IpNumber = IpNumber::TP_PLUS_PLUS; // 39
    /// IL Transport Protocol \[Dave_Presotto\]
    pub const IL: IpNumber = IpNumber::IL; // 40
    /// IPv6 encapsulation \[[RFC2473](https://datatracker.ietf.org/doc/html/rfc2473)\]
    pub const IPV6: IpNumber = IpNumber::IPV6; // 41
    /// Source Demand Routing Protocol \[Deborah_Estrin\]
    pub const SDRP: IpNumber = IpNumber::SDRP; // 42
    /// Routing Header for IPv6 \[Steve_Deering\]
    pub const IPV6_ROUTE_HEADER: IpNumber = IpNumber::IPV6_ROUTE_HEADER; // 43
    /// Routing Header for IPv6 \[Steve_Deering\]
    pub const IPV6_ROUTE: IpNumber = IpNumber::IPV6_ROUTE_HEADER; // 43
    /// Fragment Header for IPv6 \[Steve_Deering\]
    pub const IPV6_FRAGMENTATION_HEADER: IpNumber = IpNumber::IPV6_FRAGMENTATION_HEADER; // 44
    /// Fragment Header for IPv6 \[Steve_Deering\]
    pub const IPV6_FRAG: IpNumber = IpNumber::IPV6_FRAGMENTATION_HEADER; // 44
    /// Inter-Domain Routing Protocol \[Sue_Hares\]
    pub const IDRP: IpNumber = IpNumber::IDRP; // 45
    /// Reservation Protocol \[[RFC2205](https://datatracker.ietf.org/doc/html/rfc2205)\]\[[RFC3209](https://datatracker.ietf.org/doc/html/rfc3209)\]\[Bob_Braden\]
    pub const RSVP: IpNumber = IpNumber::RSVP; // 46
    /// Generic Routing Encapsulation \[[RFC2784](https://datatracker.ietf.org/doc/html/rfc2784)\]\[Tony_Li\]
    pub const GRE: IpNumber = IpNumber::GRE; // 47
    /// Dynamic Source Routing Protocol \[[RFC4728](https://datatracker.ietf.org/doc/html/rfc4728)\]
    pub const DSR: IpNumber = IpNumber::DSR; // 48
    /// BNA \[Gary Salamon\]
    pub const BNA: IpNumber = IpNumber::BNA; // 49
    /// Encapsulating Security Payload \[[RFC4303](https://datatracker.ietf.org/doc/html/rfc4303)\]
    pub const ENCAP_SEC: IpNumber = IpNumber::ENCAPSULATING_SECURITY_PAYLOAD; // 50
    /// Encapsulating Security Payload \[[RFC4303](https://datatracker.ietf.org/doc/html/rfc4303)\]
    pub const ENCAPSULATING_SECURITY_PAYLOAD: IpNumber = IpNumber::ENCAPSULATING_SECURITY_PAYLOAD; // 50
    /// Authentication Header \[[RFC4302](https://datatracker.ietf.org/doc/html/rfc4302)\]
    pub const AUTH: IpNumber = IpNumber::AUTHENTICATION_HEADER; // 51
    /// Authentication Header \[[RFC4302](https://datatracker.ietf.org/doc/html/rfc4302)\]
    pub const AUTHENTICATION_HEADER: IpNumber = IpNumber::AUTHENTICATION_HEADER; // 51
    /// Integrated Net Layer Security  TUBA \[K_Robert_Glenn\]
    pub const INLSP: IpNumber = IpNumber::INLSP; // 52
    /// IP with Encryption (deprecated) \[John_Ioannidis\]
    pub const SWIPE: IpNumber = IpNumber::SWIPE; // 53
    /// NBMA Address Resolution Protocol \[[RFC1735](https://datatracker.ietf.org/doc/html/rfc1735)\]
    pub const NARP: IpNumber = IpNumber::NARP; // 54
    /// IP Mobility \[Charlie_Perkins\]
    pub const MOBILE: IpNumber = IpNumber::MOBILE; // 55
    /// Transport Layer Security Protocol using Kryptonet key management \[Christer_Oberg\]
    pub const TLSP: IpNumber = IpNumber::TLSP; // 56
    /// SKIP \[Tom_Markson\]
    pub const SKIP: IpNumber = IpNumber::SKIP; // 57
    /// IPv6 ICMP next-header type \[[RFC4443](https://datatracker.ietf.org/doc/html/rfc4443)\]
    pub const IPV6_ICMP: IpNumber = IpNumber::IPV6_ICMP; // 58
    /// No Next Header for IPv6 \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    pub const IPV6_NO_NEXT_HEADER: IpNumber = IpNumber::IPV6_NO_NEXT_HEADER; // 59
    /// Destination Options for IPv6 \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    pub const IPV6_DEST_OPTIONS: IpNumber = IpNumber::IPV6_DESTINATION_OPTIONS; // 60
    /// Destination Options for IPv6 \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    pub const IPV6_DESTINATION_OPTIONS: IpNumber = IpNumber::IPV6_DESTINATION_OPTIONS; // 60
    /// any host internal protocol \[Internet_Assigned_Numbers_Authority\]
    pub const ANY_HOST_INTERNAL_PROTOCOL: IpNumber = IpNumber::ANY_HOST_INTERNAL_PROTOCOL; // 61
    /// CFTP \[Forsdick, H., "CFTP", Network Message, Bolt Beranek and Newman, January 1982.\]\[Harry_Forsdick\]
    pub const CFTP: IpNumber = IpNumber::CFTP; // 62
    /// any local network \[Internet_Assigned_Numbers_Authority\]
    pub const ANY_LOCAL_NETWORK: IpNumber = IpNumber::ANY_LOCAL_NETWORK; // 63
    /// SATNET and Backroom EXPAK \[Steven_Blumenthal\]
    pub const SAT_EXPAK: IpNumber = IpNumber::SAT_EXPAK; // 64
    /// Kryptolan \[Paul Liu\]
    pub const KRYTOLAN: IpNumber = IpNumber::KRYTOLAN; // 65
    /// MIT Remote Virtual Disk Protocol \[Michael_Greenwald\]
    pub const RVD: IpNumber = IpNumber::RVD; // 66
    /// Internet Pluribus Packet Core \[Steven_Blumenthal\]
    pub const IPPC: IpNumber = IpNumber::IPPC; // 67
    /// any distributed file system \[Internet_Assigned_Numbers_Authority\]
    pub const ANY_DISTRIBUTED_FILE_SYSTEM: IpNumber = IpNumber::ANY_DISTRIBUTED_FILE_SYSTEM; // 68
    /// SATNET Monitoring \[Steven_Blumenthal\]
    pub const SAT_MON: IpNumber = IpNumber::SAT_MON; // 69
    /// VISA Protocol \[Gene_Tsudik\]
    pub const VISA: IpNumber = IpNumber::VISA; // 70
    /// Internet Packet Core Utility \[Steven_Blumenthal\]
    pub const IPCV: IpNumber = IpNumber::IPCV; // 71
    /// Computer Protocol Network Executive \[David Mittnacht\]
    pub const CPNX: IpNumber = IpNumber::CPNX; // 72
    /// Computer Protocol Heart Beat \[David Mittnacht\]
    pub const CPHB: IpNumber = IpNumber::CPHB; // 73
    /// Wang Span Network \[Victor Dafoulas\]
    pub const WSN: IpNumber = IpNumber::WSN; // 74
    /// Packet Video Protocol \[Steve_Casner\]
    pub const PVP: IpNumber = IpNumber::PVP; // 75
    /// Backroom SATNET Monitoring \[Steven_Blumenthal\]
    pub const BR_SAT_MON: IpNumber = IpNumber::BR_SAT_MON; // 76
    /// SUN ND PROTOCOL-Temporary \[William_Melohn\]
    pub const SUN_ND: IpNumber = IpNumber::SUN_ND; // 77
    /// WIDEBAND Monitoring \[Steven_Blumenthal\]
    pub const WB_MON: IpNumber = IpNumber::WB_MON; // 78
    /// WIDEBAND EXPAK \[Steven_Blumenthal\]
    pub const WB_EXPAK: IpNumber = IpNumber::WB_EXPAK; // 79
    /// ISO Internet Protocol \[Marshall_T_Rose\]
    pub const ISO_IP: IpNumber = IpNumber::ISO_IP; // 80
    /// VMTP \[Dave_Cheriton\]
    pub const VMTP: IpNumber = IpNumber::VMTP; // 81
    /// SECURE-VMTP \[Dave_Cheriton\]
    pub const SECURE_VMTP: IpNumber = IpNumber::SECURE_VMTP; // 82
    /// VINES \[Brian Horn\]
    pub const VINES: IpNumber = IpNumber::VINES; // 83
    /// Transaction Transport Protocol or Internet Protocol Traffic Manager \[Jim_Stevens\]
    pub const TTP_OR_IPTM: IpNumber = IpNumber::TTP_OR_IPTM; // 84
    /// NSFNET-IGP \[Hans_Werner_Braun\]
    pub const NSFNET_IGP: IpNumber = IpNumber::NSFNET_IGP; // 85
    /// Dissimilar Gateway Protocol \[M/A-COM Government Systems, "Dissimilar Gateway Protocol Specification, Draft Version", Contract no. CS901145, November 16, 1987.\]\[Mike_Little\]
    pub const DGP: IpNumber = IpNumber::DGP; // 86
    /// TCF \[Guillermo_A_Loyola\]
    pub const TCF: IpNumber = IpNumber::TCF; // 87
    /// EIGRP \[[RFC7868](https://datatracker.ietf.org/doc/html/rfc7868)\]
    pub const EIGRP: IpNumber = IpNumber::EIGRP; // 88
    /// OSPFIGP \[[RFC1583](https://datatracker.ietf.org/doc/html/rfc1583)\]\[[RFC2328](https://datatracker.ietf.org/doc/html/rfc2328)\]\[[RFC5340](https://datatracker.ietf.org/doc/html/rfc5340)\]\[John_Moy\]
    pub const OSPFIGP: IpNumber = IpNumber::OSPFIGP; // 89
    /// Sprite RPC Protocol \[Welch, B., "The Sprite Remote Procedure Call System", Technical Report, UCB/Computer Science Dept., 86/302, University of California at Berkeley, June 1986.\]\[Bruce Willins\]
    pub const SPRITE_RPC: IpNumber = IpNumber::SPRITE_RPC; // 90
    /// Locus Address Resolution Protocol \[Brian Horn\]
    pub const LARP: IpNumber = IpNumber::LARP; // 91
    /// Multicast Transport Protocol \[Susie_Armstrong\]
    pub const MTP: IpNumber = IpNumber::MTP; // 92
    /// AX.25 Frames \[Brian_Kantor\]
    pub const AX25: IpNumber = IpNumber::AX25; // 93
    /// IP-within-IP Encapsulation Protocol \[John_Ioannidis\]
    pub const IPIP: IpNumber = IpNumber::IPIP; // 94
    /// Mobile Internetworking Control Pro. (deprecated) \[John_Ioannidis\]
    pub const MICP: IpNumber = IpNumber::MICP; // 95
    /// Semaphore Communications Sec. Pro. \[Howard_Hart\]
    pub const SCC_SP: IpNumber = IpNumber::SCC_SP; // 96
    /// Ethernet-within-IP Encapsulation \[[RFC3378](https://datatracker.ietf.org/doc/html/rfc3378)\]
    pub const ETHER_IP: IpNumber = IpNumber::ETHER_IP; // 97
    /// Encapsulation Header \[[RFC1241](https://datatracker.ietf.org/doc/html/rfc1241)\]\[Robert_Woodburn\]
    pub const ENCAP: IpNumber = IpNumber::ENCAP; // 98
    /// GMTP \[\[RXB5\]\]
    pub const GMTP: IpNumber = IpNumber::GMTP; // 100
    /// Ipsilon Flow Management Protocol \[Bob_Hinden\]\[November 1995, 1997.\]
    pub const IFMP: IpNumber = IpNumber::IFMP; // 101
    /// PNNI over IP \[Ross_Callon\]
    pub const PNNI: IpNumber = IpNumber::PNNI; // 102
    /// Protocol Independent Multicast \[[RFC7761](https://datatracker.ietf.org/doc/html/rfc7761)\]\[Dino_Farinacci\]
    pub const PIM: IpNumber = IpNumber::PIM; // 103
    /// ARIS \[Nancy_Feldman\]
    pub const ARIS: IpNumber = IpNumber::ARIS; // 104
    /// SCPS \[Robert_Durst\]
    pub const SCPS: IpNumber = IpNumber::SCPS; // 105
    /// QNX \[Michael_Hunter\]
    pub const QNX: IpNumber = IpNumber::QNX; // 106
    /// Active Networks \[Bob_Braden\]
    pub const ACTIVE_NETWORKS: IpNumber = IpNumber::ACTIVE_NETWORKS; // 107
    /// IP Payload Compression Protocol \[[RFC2393](https://datatracker.ietf.org/doc/html/rfc2393)\]
    pub const IP_COMP: IpNumber = IpNumber::IP_COMP; // 108
    /// Sitara Networks Protocol \[Manickam_R_Sridhar\]
    pub const SITRA_NETWORKS_PROTOCOL: IpNumber = IpNumber::SITRA_NETWORKS_PROTOCOL; // 109
    /// Compaq Peer Protocol \[Victor_Volpe\]
    pub const COMPAQ_PEER: IpNumber = IpNumber::COMPAQ_PEER; // 110
    /// IPX in IP \[CJ_Lee\]
    pub const IPX_IN_IP: IpNumber = IpNumber::IPX_IN_IP; // 111
    /// Virtual Router Redundancy Protocol \[[RFC5798](https://datatracker.ietf.org/doc/html/rfc5798)\]
    pub const VRRP: IpNumber = IpNumber::VRRP; // 112
    /// PGM Reliable Transport Protocol \[Tony_Speakman\]
    pub const PGM: IpNumber = IpNumber::PGM; // 113
    /// any 0-hop protocol \[Internet_Assigned_Numbers_Authority\]
    pub const ANY_ZERO_HOP_PROTOCOL: IpNumber = IpNumber::ANY_ZERO_HOP_PROTOCOL; // 114
    /// Layer Two Tunneling Protocol \[[RFC3931](https://datatracker.ietf.org/doc/html/rfc3931)\]\[Bernard_Aboba\]
    pub const LAYER2_TUNNELING_PROTOCOL: IpNumber = IpNumber::LAYER2_TUNNELING_PROTOCOL; // 115
    /// D-II Data Exchange (DDX) \[John_Worley\]
    pub const DDX: IpNumber = IpNumber::DDX; // 116
    /// Interactive Agent Transfer Protocol \[John_Murphy\]
    pub const IATP: IpNumber = IpNumber::IATP; // 117
    /// Schedule Transfer Protocol \[Jean_Michel_Pittet\]
    pub const STP: IpNumber = IpNumber::STP; // 118
    /// SpectraLink Radio Protocol \[Mark_Hamilton\]
    pub const SRP: IpNumber = IpNumber::SRP; // 119
    /// UTI \[Peter_Lothberg\]
    pub const UTI: IpNumber = IpNumber::UTI; // 120
    /// Simple Message Protocol \[Leif_Ekblad\]
    pub const SIMPLE_MESSAGE_PROTOCOL: IpNumber = IpNumber::SIMPLE_MESSAGE_PROTOCOL; // 121
    /// Simple Multicast Protocol (deprecated) \[Jon_Crowcroft\]\[draft-perlman-simple-multicast\]
    pub const SM: IpNumber = IpNumber::SM; // 122
    /// Performance Transparency Protocol \[Michael_Welzl\]
    pub const PTP: IpNumber = IpNumber::PTP; // 123
    /// ISIS over IPv4 \[Tony_Przygienda\]
    pub const ISIS_OVER_IPV4: IpNumber = IpNumber::ISIS_OVER_IPV4; // 124
    /// FIRE \[Criag_Partridge\]
    pub const FIRE: IpNumber = IpNumber::FIRE; // 125
    /// Combat Radio Transport Protocol \[Robert_Sautter\]
    pub const CRTP: IpNumber = IpNumber::CRTP; // 126
    /// Combat Radio User Datagram \[Robert_Sautter\]
    pub const CRUDP: IpNumber = IpNumber::CRUDP; // 127
    /// SSCOPMCE \[Kurt_Waber\]
    pub const SSCOPMCE: IpNumber = IpNumber::SSCOPMCE; // 128
    /// IPLT \[\[Hollbach\]\]
    pub const IPLT: IpNumber = IpNumber::IPLT; // 129
    /// Secure Packet Shield \[Bill_McIntosh\]
    pub const SPS: IpNumber = IpNumber::SPS; // 130
    /// Private IP Encapsulation within IP \[Bernhard_Petri\]
    pub const PIPE: IpNumber = IpNumber::PIPE; // 131
    /// Stream Control Transmission Protocol \[Randall_R_Stewart\]
    pub const SCTP: IpNumber = IpNumber::SCTP; // 132
    /// Fibre Channel \[Murali_Rajagopal\]\[[RFC6172](https://datatracker.ietf.org/doc/html/rfc6172)\]
    pub const FC: IpNumber = IpNumber::FC; // 133
    /// RSVP-E2E-IGNORE \[[RFC3175](https://datatracker.ietf.org/doc/html/rfc3175)\]
    pub const RSVP_E2E_IGNORE: IpNumber = IpNumber::RSVP_E2E_IGNORE; // 134
    /// MobilityHeader \[[RFC6275](https://datatracker.ietf.org/doc/html/rfc6275)\]
    pub const MOBILITY: IpNumber = IpNumber::MOBILITY_HEADER; // 135
    /// MobilityHeader \[[RFC6275](https://datatracker.ietf.org/doc/html/rfc6275)\]
    pub const MOBILITY_HEADER: IpNumber = IpNumber::MOBILITY_HEADER; // 135
    /// UDPLite \[[RFC3828](https://datatracker.ietf.org/doc/html/rfc3828)\]
    pub const UDP_LITE: IpNumber = IpNumber::UDP_LITE; // 136
    /// \[[RFC4023](https://datatracker.ietf.org/doc/html/rfc4023)\]
    pub const MPLS_IN_IP: IpNumber = IpNumber::MPLS_IN_IP; // 137
    /// MANET Protocols \[[RFC5498](https://datatracker.ietf.org/doc/html/rfc5498)\]
    pub const MANET: IpNumber = IpNumber::MANET; // 138
    /// Host Identity Protocol \[[RFC7401](https://datatracker.ietf.org/doc/html/rfc7401)\]
    pub const HIP: IpNumber = IpNumber::HIP; // 139
    /// Shim6 Protocol \[[RFC5533](https://datatracker.ietf.org/doc/html/rfc5533)\]
    pub const SHIM6: IpNumber = IpNumber::SHIM6; // 140
    /// Wrapped Encapsulating Security Payload \[[RFC5840](https://datatracker.ietf.org/doc/html/rfc5840)\]
    pub const WESP: IpNumber = IpNumber::WESP; // 141
    /// Robust Header Compression \[[RFC5858](https://datatracker.ietf.org/doc/html/rfc5858)\]
    pub const ROHC: IpNumber = IpNumber::ROHC; // 142
    /// Use for experimentation and testing
    pub const EXP0: IpNumber = IpNumber::EXPERIMENTAL_AND_TESTING_0; // 253
    /// Use for experimentation and testing
    pub const EXPERIMENTAL_AND_TESTING_0: IpNumber = IpNumber::EXPERIMENTAL_AND_TESTING_0; // 253
    /// Use for experimentation and testing
    pub const EXP1: IpNumber = IpNumber::EXPERIMENTAL_AND_TESTING_1; // 254
    /// Use for experimentation and testing
    pub const EXPERIMENTAL_AND_TESTING_1: IpNumber = IpNumber::EXPERIMENTAL_AND_TESTING_1;
    // 254
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::{
        cmp::Ordering,
        hash::{Hash, Hasher},
    };
    use proptest::prelude::*;
    use std::{collections::hash_map::DefaultHasher, format};

    #[test]
    fn is_ipv6_ext_header_value() {
        use crate::ip_number::*;
        use crate::IpNumber;
        let ext_ids = [
            IPV6_HOP_BY_HOP,
            IPV6_ROUTE,
            IPV6_FRAG,
            ENCAP_SEC,
            AUTH,
            IPV6_DEST_OPTIONS,
            MOBILITY,
            HIP,
            SHIM6,
            EXP0,
            EXP1,
        ];

        for i in 0..std::u8::MAX {
            assert_eq!(
                ext_ids.contains(&IpNumber(i)),
                IpNumber(i).is_ipv6_ext_header_value()
            );
        }
    }

    #[test]
    fn keyword_str() {
        // auto generated from CSV
        // https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
        // on 2023-04-11.
        assert_eq!(IpNumber(0).keyword_str(), Some("HOPOPT"));
        assert_eq!(IpNumber(1).keyword_str(), Some("ICMP"));
        assert_eq!(IpNumber(2).keyword_str(), Some("IGMP"));
        assert_eq!(IpNumber(3).keyword_str(), Some("GGP"));
        assert_eq!(IpNumber(4).keyword_str(), Some("IPv4"));
        assert_eq!(IpNumber(5).keyword_str(), Some("ST"));
        assert_eq!(IpNumber(6).keyword_str(), Some("TCP"));
        assert_eq!(IpNumber(7).keyword_str(), Some("CBT"));
        assert_eq!(IpNumber(8).keyword_str(), Some("EGP"));
        assert_eq!(IpNumber(9).keyword_str(), Some("IGP"));
        assert_eq!(IpNumber(10).keyword_str(), Some("BBN-RCC-MON"));
        assert_eq!(IpNumber(11).keyword_str(), Some("NVP-II"));
        assert_eq!(IpNumber(12).keyword_str(), Some("PUP"));
        assert_eq!(IpNumber(13).keyword_str(), Some("ARGUS (deprecated)"));
        assert_eq!(IpNumber(14).keyword_str(), Some("EMCON"));
        assert_eq!(IpNumber(15).keyword_str(), Some("XNET"));
        assert_eq!(IpNumber(16).keyword_str(), Some("CHAOS"));
        assert_eq!(IpNumber(17).keyword_str(), Some("UDP"));
        assert_eq!(IpNumber(18).keyword_str(), Some("MUX"));
        assert_eq!(IpNumber(19).keyword_str(), Some("DCN-MEAS"));
        assert_eq!(IpNumber(20).keyword_str(), Some("HMP"));
        assert_eq!(IpNumber(21).keyword_str(), Some("PRM"));
        assert_eq!(IpNumber(22).keyword_str(), Some("XNS-IDP"));
        assert_eq!(IpNumber(23).keyword_str(), Some("TRUNK-1"));
        assert_eq!(IpNumber(24).keyword_str(), Some("TRUNK-2"));
        assert_eq!(IpNumber(25).keyword_str(), Some("LEAF-1"));
        assert_eq!(IpNumber(26).keyword_str(), Some("LEAF-2"));
        assert_eq!(IpNumber(27).keyword_str(), Some("RDP"));
        assert_eq!(IpNumber(28).keyword_str(), Some("IRTP"));
        assert_eq!(IpNumber(29).keyword_str(), Some("ISO-TP4"));
        assert_eq!(IpNumber(30).keyword_str(), Some("NETBLT"));
        assert_eq!(IpNumber(31).keyword_str(), Some("MFE-NSP"));
        assert_eq!(IpNumber(32).keyword_str(), Some("MERIT-INP"));
        assert_eq!(IpNumber(33).keyword_str(), Some("DCCP"));
        assert_eq!(IpNumber(34).keyword_str(), Some("3PC"));
        assert_eq!(IpNumber(35).keyword_str(), Some("IDPR"));
        assert_eq!(IpNumber(36).keyword_str(), Some("XTP"));
        assert_eq!(IpNumber(37).keyword_str(), Some("DDP"));
        assert_eq!(IpNumber(38).keyword_str(), Some("IDPR-CMTP"));
        assert_eq!(IpNumber(39).keyword_str(), Some("TP++"));
        assert_eq!(IpNumber(40).keyword_str(), Some("IL"));
        assert_eq!(IpNumber(41).keyword_str(), Some("IPv6"));
        assert_eq!(IpNumber(42).keyword_str(), Some("SDRP"));
        assert_eq!(IpNumber(43).keyword_str(), Some("IPv6-Route"));
        assert_eq!(IpNumber(44).keyword_str(), Some("IPv6-Frag"));
        assert_eq!(IpNumber(45).keyword_str(), Some("IDRP"));
        assert_eq!(IpNumber(46).keyword_str(), Some("RSVP"));
        assert_eq!(IpNumber(47).keyword_str(), Some("GRE"));
        assert_eq!(IpNumber(48).keyword_str(), Some("DSR"));
        assert_eq!(IpNumber(49).keyword_str(), Some("BNA"));
        assert_eq!(IpNumber(50).keyword_str(), Some("ESP"));
        assert_eq!(IpNumber(51).keyword_str(), Some("AH"));
        assert_eq!(IpNumber(52).keyword_str(), Some("I-NLSP"));
        assert_eq!(IpNumber(53).keyword_str(), Some("SWIPE (deprecated)"));
        assert_eq!(IpNumber(54).keyword_str(), Some("NARP"));
        assert_eq!(IpNumber(55).keyword_str(), Some("MOBILE"));
        assert_eq!(IpNumber(56).keyword_str(), Some("TLSP"));
        assert_eq!(IpNumber(57).keyword_str(), Some("SKIP"));
        assert_eq!(IpNumber(58).keyword_str(), Some("IPv6-ICMP"));
        assert_eq!(IpNumber(59).keyword_str(), Some("IPv6-NoNxt"));
        assert_eq!(IpNumber(60).keyword_str(), Some("IPv6-Opts"));
        assert_eq!(IpNumber(61).keyword_str(), None);
        assert_eq!(IpNumber(62).keyword_str(), Some("CFTP"));
        assert_eq!(IpNumber(63).keyword_str(), None);
        assert_eq!(IpNumber(64).keyword_str(), Some("SAT-EXPAK"));
        assert_eq!(IpNumber(65).keyword_str(), Some("KRYPTOLAN"));
        assert_eq!(IpNumber(66).keyword_str(), Some("RVD"));
        assert_eq!(IpNumber(67).keyword_str(), Some("IPPC"));
        assert_eq!(IpNumber(68).keyword_str(), None);
        assert_eq!(IpNumber(69).keyword_str(), Some("SAT-MON"));
        assert_eq!(IpNumber(70).keyword_str(), Some("VISA"));
        assert_eq!(IpNumber(71).keyword_str(), Some("IPCV"));
        assert_eq!(IpNumber(72).keyword_str(), Some("CPNX"));
        assert_eq!(IpNumber(73).keyword_str(), Some("CPHB"));
        assert_eq!(IpNumber(74).keyword_str(), Some("WSN"));
        assert_eq!(IpNumber(75).keyword_str(), Some("PVP"));
        assert_eq!(IpNumber(76).keyword_str(), Some("BR-SAT-MON"));
        assert_eq!(IpNumber(77).keyword_str(), Some("SUN-ND"));
        assert_eq!(IpNumber(78).keyword_str(), Some("WB-MON"));
        assert_eq!(IpNumber(79).keyword_str(), Some("WB-EXPAK"));
        assert_eq!(IpNumber(80).keyword_str(), Some("ISO-IP"));
        assert_eq!(IpNumber(81).keyword_str(), Some("VMTP"));
        assert_eq!(IpNumber(82).keyword_str(), Some("SECURE-VMTP"));
        assert_eq!(IpNumber(83).keyword_str(), Some("VINES"));
        assert_eq!(IpNumber(84).keyword_str(), Some("IPTM"));
        assert_eq!(IpNumber(85).keyword_str(), Some("NSFNET-IGP"));
        assert_eq!(IpNumber(86).keyword_str(), Some("DGP"));
        assert_eq!(IpNumber(87).keyword_str(), Some("TCF"));
        assert_eq!(IpNumber(88).keyword_str(), Some("EIGRP"));
        assert_eq!(IpNumber(89).keyword_str(), Some("OSPFIGP"));
        assert_eq!(IpNumber(90).keyword_str(), Some("Sprite-RPC"));
        assert_eq!(IpNumber(91).keyword_str(), Some("LARP"));
        assert_eq!(IpNumber(92).keyword_str(), Some("MTP"));
        assert_eq!(IpNumber(93).keyword_str(), Some("AX.25"));
        assert_eq!(IpNumber(94).keyword_str(), Some("IPIP"));
        assert_eq!(IpNumber(95).keyword_str(), Some("MICP (deprecated)"));
        assert_eq!(IpNumber(96).keyword_str(), Some("SCC-SP"));
        assert_eq!(IpNumber(97).keyword_str(), Some("ETHERIP"));
        assert_eq!(IpNumber(98).keyword_str(), Some("ENCAP"));
        assert_eq!(IpNumber(99).keyword_str(), None);
        assert_eq!(IpNumber(100).keyword_str(), Some("GMTP"));
        assert_eq!(IpNumber(101).keyword_str(), Some("IFMP"));
        assert_eq!(IpNumber(102).keyword_str(), Some("PNNI"));
        assert_eq!(IpNumber(103).keyword_str(), Some("PIM"));
        assert_eq!(IpNumber(104).keyword_str(), Some("ARIS"));
        assert_eq!(IpNumber(105).keyword_str(), Some("SCPS"));
        assert_eq!(IpNumber(106).keyword_str(), Some("QNX"));
        assert_eq!(IpNumber(107).keyword_str(), Some("A/N"));
        assert_eq!(IpNumber(108).keyword_str(), Some("IPComp"));
        assert_eq!(IpNumber(109).keyword_str(), Some("SNP"));
        assert_eq!(IpNumber(110).keyword_str(), Some("Compaq-Peer"));
        assert_eq!(IpNumber(111).keyword_str(), Some("IPX-in-IP"));
        assert_eq!(IpNumber(112).keyword_str(), Some("VRRP"));
        assert_eq!(IpNumber(113).keyword_str(), Some("PGM"));
        assert_eq!(IpNumber(114).keyword_str(), None);
        assert_eq!(IpNumber(115).keyword_str(), Some("L2TP"));
        assert_eq!(IpNumber(116).keyword_str(), Some("DDX"));
        assert_eq!(IpNumber(117).keyword_str(), Some("IATP"));
        assert_eq!(IpNumber(118).keyword_str(), Some("STP"));
        assert_eq!(IpNumber(119).keyword_str(), Some("SRP"));
        assert_eq!(IpNumber(120).keyword_str(), Some("UTI"));
        assert_eq!(IpNumber(121).keyword_str(), Some("SMP"));
        assert_eq!(IpNumber(122).keyword_str(), Some("SM (deprecated)"));
        assert_eq!(IpNumber(123).keyword_str(), Some("PTP"));
        assert_eq!(IpNumber(124).keyword_str(), Some("ISIS over IPv4"));
        assert_eq!(IpNumber(125).keyword_str(), Some("FIRE"));
        assert_eq!(IpNumber(126).keyword_str(), Some("CRTP"));
        assert_eq!(IpNumber(127).keyword_str(), Some("CRUDP"));
        assert_eq!(IpNumber(128).keyword_str(), Some("SSCOPMCE"));
        assert_eq!(IpNumber(129).keyword_str(), Some("IPLT"));
        assert_eq!(IpNumber(130).keyword_str(), Some("SPS"));
        assert_eq!(IpNumber(131).keyword_str(), Some("PIPE"));
        assert_eq!(IpNumber(132).keyword_str(), Some("SCTP"));
        assert_eq!(IpNumber(133).keyword_str(), Some("FC"));
        assert_eq!(IpNumber(134).keyword_str(), Some("RSVP-E2E-IGNORE"));
        assert_eq!(IpNumber(135).keyword_str(), Some("Mobility Header"));
        assert_eq!(IpNumber(136).keyword_str(), Some("UDPLite"));
        assert_eq!(IpNumber(137).keyword_str(), Some("MPLS-in-IP"));
        assert_eq!(IpNumber(138).keyword_str(), Some("manet"));
        assert_eq!(IpNumber(139).keyword_str(), Some("HIP"));
        assert_eq!(IpNumber(140).keyword_str(), Some("Shim6"));
        assert_eq!(IpNumber(141).keyword_str(), Some("WESP"));
        assert_eq!(IpNumber(142).keyword_str(), Some("ROHC"));
        assert_eq!(IpNumber(143).keyword_str(), Some("Ethernet"));
        assert_eq!(IpNumber(144).keyword_str(), Some("AGGFRAG"));
        for i in 145u8..=252 {
            assert_eq!(IpNumber(i).keyword_str(), None);
        }
        assert_eq!(IpNumber(253).keyword_str(), None);
        assert_eq!(IpNumber(254).keyword_str(), None);
        assert_eq!(IpNumber(255).keyword_str(), Some("Reserved"));
    }

    #[test]
    fn protocol_str() {
        // auto generated from CSV
        // https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
        // on 2023-04-11.
        assert_eq!(IpNumber(0).protocol_str(), Some("IPv6 Hop-by-Hop Option"));
        assert_eq!(IpNumber(1).protocol_str(), Some("Internet Control Message"));
        assert_eq!(
            IpNumber(2).protocol_str(),
            Some("Internet Group Management")
        );
        assert_eq!(IpNumber(3).protocol_str(), Some("Gateway-to-Gateway"));
        assert_eq!(IpNumber(4).protocol_str(), Some("IPv4 encapsulation"));
        assert_eq!(IpNumber(5).protocol_str(), Some("Stream"));
        assert_eq!(IpNumber(6).protocol_str(), Some("Transmission Control"));
        assert_eq!(IpNumber(7).protocol_str(), Some("CBT"));
        assert_eq!(
            IpNumber(8).protocol_str(),
            Some("Exterior Gateway Protocol")
        );
        assert_eq!(
            IpNumber(9).protocol_str(),
            Some("any private interior gateway (used by Cisco for their IGRP)")
        );
        assert_eq!(IpNumber(10).protocol_str(), Some("BBN RCC Monitoring"));
        assert_eq!(IpNumber(11).protocol_str(), Some("Network Voice Protocol"));
        assert_eq!(IpNumber(12).protocol_str(), Some("PUP"));
        assert_eq!(IpNumber(13).protocol_str(), Some("ARGUS"));
        assert_eq!(IpNumber(14).protocol_str(), Some("EMCON"));
        assert_eq!(IpNumber(15).protocol_str(), Some("Cross Net Debugger"));
        assert_eq!(IpNumber(16).protocol_str(), Some("Chaos"));
        assert_eq!(IpNumber(17).protocol_str(), Some("User Datagram"));
        assert_eq!(IpNumber(18).protocol_str(), Some("Multiplexing"));
        assert_eq!(
            IpNumber(19).protocol_str(),
            Some("DCN Measurement Subsystems")
        );
        assert_eq!(IpNumber(20).protocol_str(), Some("Host Monitoring"));
        assert_eq!(
            IpNumber(21).protocol_str(),
            Some("Packet Radio Measurement")
        );
        assert_eq!(IpNumber(22).protocol_str(), Some("XEROX NS IDP"));
        assert_eq!(IpNumber(23).protocol_str(), Some("Trunk-1"));
        assert_eq!(IpNumber(24).protocol_str(), Some("Trunk-2"));
        assert_eq!(IpNumber(25).protocol_str(), Some("Leaf-1"));
        assert_eq!(IpNumber(26).protocol_str(), Some("Leaf-2"));
        assert_eq!(IpNumber(27).protocol_str(), Some("Reliable Data Protocol"));
        assert_eq!(
            IpNumber(28).protocol_str(),
            Some("Internet Reliable Transaction")
        );
        assert_eq!(
            IpNumber(29).protocol_str(),
            Some("ISO Transport Protocol Class 4")
        );
        assert_eq!(
            IpNumber(30).protocol_str(),
            Some("Bulk Data Transfer Protocol")
        );
        assert_eq!(
            IpNumber(31).protocol_str(),
            Some("MFE Network Services Protocol")
        );
        assert_eq!(
            IpNumber(32).protocol_str(),
            Some("MERIT Internodal Protocol")
        );
        assert_eq!(
            IpNumber(33).protocol_str(),
            Some("Datagram Congestion Control Protocol")
        );
        assert_eq!(
            IpNumber(34).protocol_str(),
            Some("Third Party Connect Protocol")
        );
        assert_eq!(
            IpNumber(35).protocol_str(),
            Some("Inter-Domain Policy Routing Protocol")
        );
        assert_eq!(IpNumber(36).protocol_str(), Some("XTP"));
        assert_eq!(
            IpNumber(37).protocol_str(),
            Some("Datagram Delivery Protocol")
        );
        assert_eq!(
            IpNumber(38).protocol_str(),
            Some("IDPR Control Message Transport Proto")
        );
        assert_eq!(IpNumber(39).protocol_str(), Some("TP++ Transport Protocol"));
        assert_eq!(IpNumber(40).protocol_str(), Some("IL Transport Protocol"));
        assert_eq!(IpNumber(41).protocol_str(), Some("IPv6 encapsulation"));
        assert_eq!(
            IpNumber(42).protocol_str(),
            Some("Source Demand Routing Protocol")
        );
        assert_eq!(IpNumber(43).protocol_str(), Some("Routing Header for IPv6"));
        assert_eq!(
            IpNumber(44).protocol_str(),
            Some("Fragment Header for IPv6")
        );
        assert_eq!(
            IpNumber(45).protocol_str(),
            Some("Inter-Domain Routing Protocol")
        );
        assert_eq!(IpNumber(46).protocol_str(), Some("Reservation Protocol"));
        assert_eq!(
            IpNumber(47).protocol_str(),
            Some("Generic Routing Encapsulation")
        );
        assert_eq!(
            IpNumber(48).protocol_str(),
            Some("Dynamic Source Routing Protocol")
        );
        assert_eq!(IpNumber(49).protocol_str(), Some("BNA"));
        assert_eq!(IpNumber(50).protocol_str(), Some("Encap Security Payload"));
        assert_eq!(IpNumber(51).protocol_str(), Some("Authentication Header"));
        assert_eq!(
            IpNumber(52).protocol_str(),
            Some("Integrated Net Layer Security  TUBA")
        );
        assert_eq!(IpNumber(53).protocol_str(), Some("IP with Encryption"));
        assert_eq!(
            IpNumber(54).protocol_str(),
            Some("NBMA Address Resolution Protocol")
        );
        assert_eq!(IpNumber(55).protocol_str(), Some("IP Mobility"));
        assert_eq!(
            IpNumber(56).protocol_str(),
            Some("Transport Layer Security Protocol using Kryptonet key management")
        );
        assert_eq!(IpNumber(57).protocol_str(), Some("SKIP"));
        assert_eq!(IpNumber(58).protocol_str(), Some("ICMP for IPv6"));
        assert_eq!(IpNumber(59).protocol_str(), Some("No Next Header for IPv6"));
        assert_eq!(
            IpNumber(60).protocol_str(),
            Some("Destination Options for IPv6")
        );
        assert_eq!(
            IpNumber(61).protocol_str(),
            Some("any host internal protocol")
        );
        assert_eq!(IpNumber(62).protocol_str(), Some("CFTP"));
        assert_eq!(IpNumber(63).protocol_str(), Some("any local network"));
        assert_eq!(
            IpNumber(64).protocol_str(),
            Some("SATNET and Backroom EXPAK")
        );
        assert_eq!(IpNumber(65).protocol_str(), Some("Kryptolan"));
        assert_eq!(
            IpNumber(66).protocol_str(),
            Some("MIT Remote Virtual Disk Protocol")
        );
        assert_eq!(
            IpNumber(67).protocol_str(),
            Some("Internet Pluribus Packet Core")
        );
        assert_eq!(
            IpNumber(68).protocol_str(),
            Some("any distributed file system")
        );
        assert_eq!(IpNumber(69).protocol_str(), Some("SATNET Monitoring"));
        assert_eq!(IpNumber(70).protocol_str(), Some("VISA Protocol"));
        assert_eq!(
            IpNumber(71).protocol_str(),
            Some("Internet Packet Core Utility")
        );
        assert_eq!(
            IpNumber(72).protocol_str(),
            Some("Computer Protocol Network Executive")
        );
        assert_eq!(
            IpNumber(73).protocol_str(),
            Some("Computer Protocol Heart Beat")
        );
        assert_eq!(IpNumber(74).protocol_str(), Some("Wang Span Network"));
        assert_eq!(IpNumber(75).protocol_str(), Some("Packet Video Protocol"));
        assert_eq!(
            IpNumber(76).protocol_str(),
            Some("Backroom SATNET Monitoring")
        );
        assert_eq!(
            IpNumber(77).protocol_str(),
            Some("SUN ND PROTOCOL-Temporary")
        );
        assert_eq!(IpNumber(78).protocol_str(), Some("WIDEBAND Monitoring"));
        assert_eq!(IpNumber(79).protocol_str(), Some("WIDEBAND EXPAK"));
        assert_eq!(IpNumber(80).protocol_str(), Some("ISO Internet Protocol"));
        assert_eq!(IpNumber(81).protocol_str(), Some("VMTP"));
        assert_eq!(IpNumber(82).protocol_str(), Some("SECURE-VMTP"));
        assert_eq!(IpNumber(83).protocol_str(), Some("VINES"));
        assert_eq!(
            IpNumber(84).protocol_str(),
            Some("Internet Protocol Traffic Manager")
        );
        assert_eq!(IpNumber(85).protocol_str(), Some("NSFNET-IGP"));
        assert_eq!(
            IpNumber(86).protocol_str(),
            Some("Dissimilar Gateway Protocol")
        );
        assert_eq!(IpNumber(87).protocol_str(), Some("TCF"));
        assert_eq!(IpNumber(88).protocol_str(), Some("EIGRP"));
        assert_eq!(IpNumber(89).protocol_str(), Some("OSPFIGP"));
        assert_eq!(IpNumber(90).protocol_str(), Some("Sprite RPC Protocol"));
        assert_eq!(
            IpNumber(91).protocol_str(),
            Some("Locus Address Resolution Protocol")
        );
        assert_eq!(
            IpNumber(92).protocol_str(),
            Some("Multicast Transport Protocol")
        );
        assert_eq!(IpNumber(93).protocol_str(), Some("AX.25 Frames"));
        assert_eq!(
            IpNumber(94).protocol_str(),
            Some("IP-within-IP Encapsulation Protocol")
        );
        assert_eq!(
            IpNumber(95).protocol_str(),
            Some("Mobile Internetworking Control Pro.")
        );
        assert_eq!(
            IpNumber(96).protocol_str(),
            Some("Semaphore Communications Sec. Pro.")
        );
        assert_eq!(
            IpNumber(97).protocol_str(),
            Some("Ethernet-within-IP Encapsulation")
        );
        assert_eq!(IpNumber(98).protocol_str(), Some("Encapsulation Header"));
        assert_eq!(
            IpNumber(99).protocol_str(),
            Some("any private encryption scheme")
        );
        assert_eq!(IpNumber(100).protocol_str(), Some("GMTP"));
        assert_eq!(
            IpNumber(101).protocol_str(),
            Some("Ipsilon Flow Management Protocol")
        );
        assert_eq!(IpNumber(102).protocol_str(), Some("PNNI over IP"));
        assert_eq!(
            IpNumber(103).protocol_str(),
            Some("Protocol Independent Multicast")
        );
        assert_eq!(IpNumber(104).protocol_str(), Some("ARIS"));
        assert_eq!(IpNumber(105).protocol_str(), Some("SCPS"));
        assert_eq!(IpNumber(106).protocol_str(), Some("QNX"));
        assert_eq!(IpNumber(107).protocol_str(), Some("Active Networks"));
        assert_eq!(
            IpNumber(108).protocol_str(),
            Some("IP Payload Compression Protocol")
        );
        assert_eq!(
            IpNumber(109).protocol_str(),
            Some("Sitara Networks Protocol")
        );
        assert_eq!(IpNumber(110).protocol_str(), Some("Compaq Peer Protocol"));
        assert_eq!(IpNumber(111).protocol_str(), Some("IPX in IP"));
        assert_eq!(
            IpNumber(112).protocol_str(),
            Some("Virtual Router Redundancy Protocol")
        );
        assert_eq!(
            IpNumber(113).protocol_str(),
            Some("PGM Reliable Transport Protocol")
        );
        assert_eq!(IpNumber(114).protocol_str(), Some("any 0-hop protocol"));
        assert_eq!(
            IpNumber(115).protocol_str(),
            Some("Layer Two Tunneling Protocol")
        );
        assert_eq!(
            IpNumber(116).protocol_str(),
            Some("D-II Data Exchange (DDX)")
        );
        assert_eq!(
            IpNumber(117).protocol_str(),
            Some("Interactive Agent Transfer Protocol")
        );
        assert_eq!(
            IpNumber(118).protocol_str(),
            Some("Schedule Transfer Protocol")
        );
        assert_eq!(
            IpNumber(119).protocol_str(),
            Some("SpectraLink Radio Protocol")
        );
        assert_eq!(IpNumber(120).protocol_str(), Some("UTI"));
        assert_eq!(
            IpNumber(121).protocol_str(),
            Some("Simple Message Protocol")
        );
        assert_eq!(
            IpNumber(122).protocol_str(),
            Some("Simple Multicast Protocol")
        );
        assert_eq!(
            IpNumber(123).protocol_str(),
            Some("Performance Transparency Protocol")
        );
        assert_eq!(IpNumber(124).protocol_str(), None);
        assert_eq!(IpNumber(125).protocol_str(), None);
        assert_eq!(
            IpNumber(126).protocol_str(),
            Some("Combat Radio Transport Protocol")
        );
        assert_eq!(
            IpNumber(127).protocol_str(),
            Some("Combat Radio User Datagram")
        );
        assert_eq!(IpNumber(128).protocol_str(), None);
        assert_eq!(IpNumber(129).protocol_str(), None);
        assert_eq!(IpNumber(130).protocol_str(), Some("Secure Packet Shield"));
        assert_eq!(
            IpNumber(131).protocol_str(),
            Some("Private IP Encapsulation within IP")
        );
        assert_eq!(
            IpNumber(132).protocol_str(),
            Some("Stream Control Transmission Protocol")
        );
        assert_eq!(IpNumber(133).protocol_str(), Some("Fibre Channel"));
        assert_eq!(IpNumber(134).protocol_str(), None);
        assert_eq!(IpNumber(135).protocol_str(), None);
        assert_eq!(IpNumber(136).protocol_str(), None);
        assert_eq!(IpNumber(137).protocol_str(), None);
        assert_eq!(IpNumber(138).protocol_str(), Some("MANET Protocols"));
        assert_eq!(IpNumber(139).protocol_str(), Some("Host Identity Protocol"));
        assert_eq!(IpNumber(140).protocol_str(), Some("Shim6 Protocol"));
        assert_eq!(
            IpNumber(141).protocol_str(),
            Some("Wrapped Encapsulating Security Payload")
        );
        assert_eq!(
            IpNumber(142).protocol_str(),
            Some("Robust Header Compression")
        );
        assert_eq!(IpNumber(143).protocol_str(), Some("Ethernet"));
        assert_eq!(
            IpNumber(144).protocol_str(),
            Some("AGGFRAG encapsulation payload for ESP")
        );
        for i in 145u8..=252 {
            assert_eq!(IpNumber(i).protocol_str(), None);
        }
        assert_eq!(
            IpNumber(253).protocol_str(),
            Some("Use for experimentation and testing")
        );
        assert_eq!(
            IpNumber(254).protocol_str(),
            Some("Use for experimentation and testing")
        );
        assert_eq!(IpNumber(255).protocol_str(), None);
    }

    #[test]
    fn ip_number_eq_check() {
        use crate::ip_number::*;
        use crate::IpNumber;
        let pairs = &[
            (IPV6_HOP_BY_HOP, IpNumber::IPV6_HEADER_HOP_BY_HOP),
            (IPV6_HEADER_HOP_BY_HOP, IpNumber::IPV6_HEADER_HOP_BY_HOP),
            (ICMP, IpNumber::ICMP),
            (IGMP, IpNumber::IGMP),
            (GGP, IpNumber::GGP),
            (IPV4, IpNumber::IPV4),
            (STREAM, IpNumber::STREAM),
            (TCP, IpNumber::TCP),
            (CBT, IpNumber::CBT),
            (EGP, IpNumber::EGP),
            (IGP, IpNumber::IGP),
            (BBN_RCC_MON, IpNumber::BBN_RCC_MON),
            (NVP_II, IpNumber::NVP_II),
            (PUP, IpNumber::PUP),
            (ARGUS, IpNumber::ARGUS),
            (EMCON, IpNumber::EMCON),
            (XNET, IpNumber::XNET),
            (CHAOS, IpNumber::CHAOS),
            (UDP, IpNumber::UDP),
            (MUX, IpNumber::MUX),
            (DCN_MEAS, IpNumber::DCN_MEAS),
            (HMP, IpNumber::HMP),
            (PRM, IpNumber::PRM),
            (XNS_IDP, IpNumber::XNS_IDP),
            (TRUNK1, IpNumber::TRUNK1),
            (TRUNK2, IpNumber::TRUNK2),
            (LEAF1, IpNumber::LEAF1),
            (LEAF2, IpNumber::LEAF2),
            (RDP, IpNumber::RDP),
            (IRTP, IpNumber::IRTP),
            (ISO_TP4, IpNumber::ISO_TP4),
            (NET_BLT, IpNumber::NET_BLT),
            (MFE_NSP, IpNumber::MFE_NSP),
            (MERIT_INP, IpNumber::MERIT_INP),
            (DCCP, IpNumber::DCCP),
            (
                THIRD_PARTY_CONNECT_PROTOCOL,
                IpNumber::THIRD_PARTY_CONNECT_PROTOCOL,
            ),
            (IDPR, IpNumber::IDPR),
            (XTP, IpNumber::XTP),
            (DDP, IpNumber::DDP),
            (IDPR_CMTP, IpNumber::IDPR_CMTP),
            (TP_PLUS_PLUS, IpNumber::TP_PLUS_PLUS),
            (IL, IpNumber::IL),
            (IPV6, IpNumber::IPV6),
            (SDRP, IpNumber::SDRP),
            (IPV6_ROUTE_HEADER, IpNumber::IPV6_ROUTE_HEADER),
            (IPV6_ROUTE, IpNumber::IPV6_ROUTE_HEADER),
            (
                IPV6_FRAGMENTATION_HEADER,
                IpNumber::IPV6_FRAGMENTATION_HEADER,
            ),
            (IPV6_FRAG, IpNumber::IPV6_FRAGMENTATION_HEADER),
            (IDRP, IpNumber::IDRP),
            (RSVP, IpNumber::RSVP),
            (GRE, IpNumber::GRE),
            (DSR, IpNumber::DSR),
            (BNA, IpNumber::BNA),
            (ENCAP_SEC, IpNumber::ENCAPSULATING_SECURITY_PAYLOAD),
            (
                ENCAPSULATING_SECURITY_PAYLOAD,
                IpNumber::ENCAPSULATING_SECURITY_PAYLOAD,
            ),
            (AUTH, IpNumber::AUTHENTICATION_HEADER),
            (AUTHENTICATION_HEADER, IpNumber::AUTHENTICATION_HEADER),
            (INLSP, IpNumber::INLSP),
            (SWIPE, IpNumber::SWIPE),
            (NARP, IpNumber::NARP),
            (MOBILE, IpNumber::MOBILE),
            (TLSP, IpNumber::TLSP),
            (SKIP, IpNumber::SKIP),
            (IPV6_ICMP, IpNumber::IPV6_ICMP),
            (IPV6_NO_NEXT_HEADER, IpNumber::IPV6_NO_NEXT_HEADER),
            (IPV6_DEST_OPTIONS, IpNumber::IPV6_DESTINATION_OPTIONS),
            (IPV6_DESTINATION_OPTIONS, IpNumber::IPV6_DESTINATION_OPTIONS),
            (
                ANY_HOST_INTERNAL_PROTOCOL,
                IpNumber::ANY_HOST_INTERNAL_PROTOCOL,
            ),
            (CFTP, IpNumber::CFTP),
            (ANY_LOCAL_NETWORK, IpNumber::ANY_LOCAL_NETWORK),
            (SAT_EXPAK, IpNumber::SAT_EXPAK),
            (KRYTOLAN, IpNumber::KRYTOLAN),
            (RVD, IpNumber::RVD),
            (IPPC, IpNumber::IPPC),
            (
                ANY_DISTRIBUTED_FILE_SYSTEM,
                IpNumber::ANY_DISTRIBUTED_FILE_SYSTEM,
            ),
            (SAT_MON, IpNumber::SAT_MON),
            (VISA, IpNumber::VISA),
            (IPCV, IpNumber::IPCV),
            (CPNX, IpNumber::CPNX),
            (CPHB, IpNumber::CPHB),
            (WSN, IpNumber::WSN),
            (PVP, IpNumber::PVP),
            (BR_SAT_MON, IpNumber::BR_SAT_MON),
            (SUN_ND, IpNumber::SUN_ND),
            (WB_MON, IpNumber::WB_MON),
            (WB_EXPAK, IpNumber::WB_EXPAK),
            (ISO_IP, IpNumber::ISO_IP),
            (VMTP, IpNumber::VMTP),
            (SECURE_VMTP, IpNumber::SECURE_VMTP),
            (VINES, IpNumber::VINES),
            (TTP_OR_IPTM, IpNumber::TTP_OR_IPTM),
            (NSFNET_IGP, IpNumber::NSFNET_IGP),
            (DGP, IpNumber::DGP),
            (TCF, IpNumber::TCF),
            (EIGRP, IpNumber::EIGRP),
            (OSPFIGP, IpNumber::OSPFIGP),
            (SPRITE_RPC, IpNumber::SPRITE_RPC),
            (LARP, IpNumber::LARP),
            (MTP, IpNumber::MTP),
            (AX25, IpNumber::AX25),
            (IPIP, IpNumber::IPIP),
            (MICP, IpNumber::MICP),
            (SCC_SP, IpNumber::SCC_SP),
            (ETHER_IP, IpNumber::ETHER_IP),
            (ENCAP, IpNumber::ENCAP),
            (GMTP, IpNumber::GMTP),
            (IFMP, IpNumber::IFMP),
            (PNNI, IpNumber::PNNI),
            (PIM, IpNumber::PIM),
            (ARIS, IpNumber::ARIS),
            (SCPS, IpNumber::SCPS),
            (QNX, IpNumber::QNX),
            (ACTIVE_NETWORKS, IpNumber::ACTIVE_NETWORKS),
            (IP_COMP, IpNumber::IP_COMP),
            (SITRA_NETWORKS_PROTOCOL, IpNumber::SITRA_NETWORKS_PROTOCOL),
            (COMPAQ_PEER, IpNumber::COMPAQ_PEER),
            (IPX_IN_IP, IpNumber::IPX_IN_IP),
            (VRRP, IpNumber::VRRP),
            (PGM, IpNumber::PGM),
            (ANY_ZERO_HOP_PROTOCOL, IpNumber::ANY_ZERO_HOP_PROTOCOL),
            (
                LAYER2_TUNNELING_PROTOCOL,
                IpNumber::LAYER2_TUNNELING_PROTOCOL,
            ),
            (DDX, IpNumber::DDX),
            (IATP, IpNumber::IATP),
            (STP, IpNumber::STP),
            (SRP, IpNumber::SRP),
            (UTI, IpNumber::UTI),
            (SIMPLE_MESSAGE_PROTOCOL, IpNumber::SIMPLE_MESSAGE_PROTOCOL),
            (SM, IpNumber::SM),
            (PTP, IpNumber::PTP),
            (ISIS_OVER_IPV4, IpNumber::ISIS_OVER_IPV4),
            (FIRE, IpNumber::FIRE),
            (CRTP, IpNumber::CRTP),
            (CRUDP, IpNumber::CRUDP),
            (SSCOPMCE, IpNumber::SSCOPMCE),
            (IPLT, IpNumber::IPLT),
            (SPS, IpNumber::SPS),
            (PIPE, IpNumber::PIPE),
            (SCTP, IpNumber::SCTP),
            (FC, IpNumber::FC),
            (RSVP_E2E_IGNORE, IpNumber::RSVP_E2E_IGNORE),
            (MOBILITY, IpNumber::MOBILITY_HEADER),
            (MOBILITY_HEADER, IpNumber::MOBILITY_HEADER),
            (UDP_LITE, IpNumber::UDP_LITE),
            (MPLS_IN_IP, IpNumber::MPLS_IN_IP),
            (MANET, IpNumber::MANET),
            (HIP, IpNumber::HIP),
            (SHIM6, IpNumber::SHIM6),
            (WESP, IpNumber::WESP),
            (ROHC, IpNumber::ROHC),
            (EXP0, IpNumber::EXPERIMENTAL_AND_TESTING_0),
            (
                EXPERIMENTAL_AND_TESTING_0,
                IpNumber::EXPERIMENTAL_AND_TESTING_0,
            ),
            (EXP1, IpNumber::EXPERIMENTAL_AND_TESTING_1),
            (
                EXPERIMENTAL_AND_TESTING_1,
                IpNumber::EXPERIMENTAL_AND_TESTING_1,
            ),
        ];
        for (raw, enum_value) in pairs {
            assert_eq!(*raw, *enum_value);
        }
    }

    #[test]
    fn default() {
        let actual: IpNumber = Default::default();
        assert_eq!(actual, IpNumber(255));
    }

    proptest! {
        #[test]
        fn into(num in any::<u8>()) {
            {
                let converted: u8 = IpNumber(num).into();
                assert_eq!(converted, num);
            }
            {
                let converted: IpNumber = num.into();
                assert_eq!(converted, IpNumber(num));
            }
        }
    }

    proptest! {
        #[test]
        fn from(num in any::<u8>()) {
            {
                let converted: u8 = u8::from(IpNumber(num));
                assert_eq!(converted, num);
            }
            {
                let converted: IpNumber = IpNumber::from(num);
                assert_eq!(converted, IpNumber(num));
            }
        }
    }

    #[test]
    fn debug() {
        // keyword & protocol string exist
        assert_eq!(
            format!("{:?}", IpNumber::UDP),
            format!("17 (UDP - User Datagram)")
        );
        // only keyword string exist
        assert_eq!(
            format!("{:?}", IpNumber::MOBILITY_HEADER),
            format!("135 (Mobility Header)")
        );
        // only protocol string exist
        assert_eq!(
            format!("{:?}", IpNumber(253)),
            format!("253 (Use for experimentation and testing)")
        );
        // no keyword & no protocol string
        assert_eq!(format!("{:?}", IpNumber(145)), format!("145"));
    }

    #[test]
    fn clone_eq_hash_ord() {
        // clone eq
        let value = IpNumber::IPV6_HEADER_HOP_BY_HOP;
        assert_eq!(value, value.clone());
        // hash
        let a_hash = {
            let mut s = DefaultHasher::new();
            value.hash(&mut s);
            s.finish()
        };
        let b_hash = {
            let mut s = DefaultHasher::new();
            value.hash(&mut s);
            s.finish()
        };
        assert_eq!(a_hash, b_hash);
        // order
        assert_eq!(value.cmp(&value.clone()), Ordering::Equal);
        assert!(value.ge(&value.clone()));
    }
}
