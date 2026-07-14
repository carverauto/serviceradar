/// Represents an non standard ethertype. These are defined in the Linux
/// kernel with ids under 1500 so they don't clash with the standard ones.
///
/// You can convert any valid `u16` value to an `LinuxNonstandardEtherType` and
/// the other way around.
///
/// ```
/// use etherparse::LinuxNonstandardEtherType;
///
/// // Convert to LinuxNonstandardEtherType using the from & into trait
/// let link_type: LinuxNonstandardEtherType = 0x0001.try_into().unwrap();
/// assert_eq!(LinuxNonstandardEtherType::N802_3, link_type);
///
/// // convert to u16 using the from & into trait
/// let num: u16 = LinuxNonstandardEtherType::N802_3.try_into().unwrap();
/// assert_eq!(0x0001, num);
/// ```
#[derive(Clone, Copy, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct LinuxNonstandardEtherType(pub(crate) u16);

impl LinuxNonstandardEtherType {
    // Numbers sourced from https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/include/uapi/linux/if_ether.h?id=e33c4963bf536900f917fb65a687724d5539bc21

    pub const N802_3: LinuxNonstandardEtherType = Self(0x0001);
    pub const AX25: LinuxNonstandardEtherType = Self(0x0002);
    pub const ALL: LinuxNonstandardEtherType = Self(0x0003);
    pub const N802_2: LinuxNonstandardEtherType = Self(0x0004);
    pub const SNAP: LinuxNonstandardEtherType = Self(0x0005);
    pub const DDCMP: LinuxNonstandardEtherType = Self(0x0006);
    pub const WAN_PPP: LinuxNonstandardEtherType = Self(0x0007);
    pub const PPP_MP: LinuxNonstandardEtherType = Self(0x0008);
    pub const LOCALTALK: LinuxNonstandardEtherType = Self(0x0009);
    pub const CAN: LinuxNonstandardEtherType = Self(0x000C);
    pub const CANFD: LinuxNonstandardEtherType = Self(0x000D);
    pub const CANXL: LinuxNonstandardEtherType = Self(0x000E);
    pub const PPPTALK: LinuxNonstandardEtherType = Self(0x0010);
    pub const TR_802_2: LinuxNonstandardEtherType = Self(0x0011);
    pub const MOBITEX: LinuxNonstandardEtherType = Self(0x0015);
    pub const CONTROL: LinuxNonstandardEtherType = Self(0x0016);
    pub const IRDA: LinuxNonstandardEtherType = Self(0x0017);
    pub const ECONET: LinuxNonstandardEtherType = Self(0x0018);
    pub const HDLC: LinuxNonstandardEtherType = Self(0x0019);
    pub const ARCNET: LinuxNonstandardEtherType = Self(0x001A);
    pub const DSA: LinuxNonstandardEtherType = Self(0x001B);
    pub const TRAILER: LinuxNonstandardEtherType = Self(0x001C);
    pub const PHONET: LinuxNonstandardEtherType = Self(0x00F5);
    pub const IEEE802154: LinuxNonstandardEtherType = Self(0x00F6);
    pub const CAIF: LinuxNonstandardEtherType = Self(0x00F7);
    pub const XDSA: LinuxNonstandardEtherType = Self(0x00F8);
    pub const MAP: LinuxNonstandardEtherType = Self(0x00F9);
    pub const MCTP: LinuxNonstandardEtherType = Self(0x00FA);
}

impl Default for LinuxNonstandardEtherType {
    fn default() -> Self {
        Self::N802_3
    }
}

impl TryFrom<u16> for LinuxNonstandardEtherType {
    type Error = ();

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            0x0000 => Err(()),
            0x0001 => Ok(LinuxNonstandardEtherType::N802_3),
            0x0002 => Ok(LinuxNonstandardEtherType::AX25),
            0x0003 => Ok(LinuxNonstandardEtherType::ALL),
            0x0004 => Ok(LinuxNonstandardEtherType::N802_2),
            0x0005 => Ok(LinuxNonstandardEtherType::SNAP),
            0x0006 => Ok(LinuxNonstandardEtherType::DDCMP),
            0x0007 => Ok(LinuxNonstandardEtherType::WAN_PPP),
            0x0008 => Ok(LinuxNonstandardEtherType::PPP_MP),
            0x0009 => Ok(LinuxNonstandardEtherType::LOCALTALK),
            0x000A..=0x000B => Err(()),
            0x000C => Ok(LinuxNonstandardEtherType::CAN),
            0x000D => Ok(LinuxNonstandardEtherType::CANFD),
            0x000E => Ok(LinuxNonstandardEtherType::CANXL),
            0x000F => Err(()),
            0x0010 => Ok(LinuxNonstandardEtherType::PPPTALK),
            0x0011 => Ok(LinuxNonstandardEtherType::TR_802_2),
            0x0012..=0x0014 => Err(()),
            0x0015 => Ok(LinuxNonstandardEtherType::MOBITEX),
            0x0016 => Ok(LinuxNonstandardEtherType::CONTROL),
            0x0017 => Ok(LinuxNonstandardEtherType::IRDA),
            0x0018 => Ok(LinuxNonstandardEtherType::ECONET),
            0x0019 => Ok(LinuxNonstandardEtherType::HDLC),
            0x001A => Ok(LinuxNonstandardEtherType::ARCNET),
            0x001B => Ok(LinuxNonstandardEtherType::DSA),
            0x001C => Ok(LinuxNonstandardEtherType::TRAILER),
            0x001D..=0x00F4 => Err(()),
            0x00F5 => Ok(LinuxNonstandardEtherType::PHONET),
            0x00F6 => Ok(LinuxNonstandardEtherType::IEEE802154),
            0x00F7 => Ok(LinuxNonstandardEtherType::CAIF),
            0x00F8 => Ok(LinuxNonstandardEtherType::XDSA),
            0x00F9 => Ok(LinuxNonstandardEtherType::MAP),
            0x00FA => Ok(LinuxNonstandardEtherType::MCTP),
            0x00FB..=u16::MAX => Err(()),
        }
    }
}

impl From<LinuxNonstandardEtherType> for u16 {
    #[inline]
    fn from(val: LinuxNonstandardEtherType) -> Self {
        val.0
    }
}

impl core::fmt::Debug for LinuxNonstandardEtherType {
    // Descriptions sourced from https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/include/uapi/linux/if_ether.h?id=e33c4963bf536900f917fb65a687724d5539bc21

    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match *self {
            LinuxNonstandardEtherType(0x0000) => write!(f, "{:#06X} (Unknown)", self.0),
            LinuxNonstandardEtherType::N802_3 => {
                write!(f, "{:#06X} (Dummy type for 802.3 frames)", self.0)
            }
            LinuxNonstandardEtherType::AX25 => {
                write!(f, "{:#06X} (Dummy protocol id for AX.25)", self.0)
            }
            LinuxNonstandardEtherType::ALL => write!(f, "{:#06X} (Every packet)", self.0),
            LinuxNonstandardEtherType::N802_2 => write!(f, "{:#06X} (802.2 frames)", self.0),
            LinuxNonstandardEtherType::SNAP => write!(f, "{:#06X} (SNAP: Internal only)", self.0),
            LinuxNonstandardEtherType::DDCMP => {
                write!(f, "{:#06X} (DEC DDCMP: Internal only)", self.0)
            }
            LinuxNonstandardEtherType::WAN_PPP => {
                write!(f, "{:#06X} (Dummy type for WAN PPP frames)", self.0)
            }
            LinuxNonstandardEtherType::PPP_MP => {
                write!(f, "{:#06X} (Dummy type for PPP MP frames)", self.0)
            }
            LinuxNonstandardEtherType::LOCALTALK => {
                write!(f, "{:#06X} (Localtalk pseudo type)", self.0)
            }
            LinuxNonstandardEtherType(0x000A..=0x000B) => write!(f, "{:#06X} (Unknown)", self.0),
            LinuxNonstandardEtherType::CAN => {
                write!(f, "{:#06X} (CAN: Controller Area Network)", self.0)
            }
            LinuxNonstandardEtherType::CANFD => {
                write!(f, "{:#06X} (CANFD: CAN flexible data rate)", self.0)
            }
            LinuxNonstandardEtherType::CANXL => {
                write!(f, "{:#06X} (CANXL: eXtended frame Length)", self.0)
            }
            LinuxNonstandardEtherType(0x000F) => write!(f, "{:#06X} (Unknown)", self.0),
            LinuxNonstandardEtherType::PPPTALK => {
                write!(f, "{:#06X} (Dummy type for Atalk over PPP)", self.0)
            }
            LinuxNonstandardEtherType::TR_802_2 => write!(f, "{:#06X} (802.2 frames)", self.0),
            LinuxNonstandardEtherType(0x0012..=0x0014) => write!(f, "{:#06X} (Unknown)", self.0),
            LinuxNonstandardEtherType::MOBITEX => write!(f, "{:#06X} (Mobitex)", self.0),
            LinuxNonstandardEtherType::CONTROL => {
                write!(f, "{:#06X} (Card specific control frames)", self.0)
            }
            LinuxNonstandardEtherType::IRDA => write!(f, "{:#06X} (Linux-IrDA)", self.0),
            LinuxNonstandardEtherType::ECONET => write!(f, "{:#06X} (Acorn Econet)", self.0),
            LinuxNonstandardEtherType::HDLC => write!(f, "{:#06X} (HDLC frames)", self.0),
            LinuxNonstandardEtherType::ARCNET => write!(f, "{:#06X} (1A for ArcNet)", self.0),
            LinuxNonstandardEtherType::DSA => {
                write!(f, "{:#06X} (Distributed Switch Arch)", self.0)
            }
            LinuxNonstandardEtherType::TRAILER => {
                write!(f, "{:#06X} (Trailer switch tagging)", self.0)
            }
            LinuxNonstandardEtherType(0x001D..=0x00F4) => write!(f, "{:#06X} (Unknown)", self.0),
            LinuxNonstandardEtherType::PHONET => write!(f, "{:#06X} (Nokia Phonet frame)", self.0),
            LinuxNonstandardEtherType::IEEE802154 => {
                write!(f, "{:#06X} (IEEE802.15.4 frame)", self.0)
            }
            LinuxNonstandardEtherType::CAIF => {
                write!(f, "{:#06X} (ST-Ericsson CAIF protocol)", self.0)
            }
            LinuxNonstandardEtherType::XDSA => {
                write!(f, "{:#06X} (Multiplexed DSA protocol)", self.0)
            }
            LinuxNonstandardEtherType::MAP => write!(
                f,
                "{:#06X} (Qualcomm multiplexing and aggregation protocol)",
                self.0
            ),
            LinuxNonstandardEtherType::MCTP => write!(
                f,
                "{:#06X} (Management component transport protocol packets)",
                self.0
            ),
            LinuxNonstandardEtherType(0x00FB..=u16::MAX) => write!(f, "{:#06X} (Unknown)", self.0),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use alloc::format;

    #[test]
    fn to_u16() {
        assert_eq!(0x0001, u16::from(LinuxNonstandardEtherType::N802_3));
        assert_eq!(0x0002, u16::from(LinuxNonstandardEtherType::AX25));
        assert_eq!(0x0003, u16::from(LinuxNonstandardEtherType::ALL));
        assert_eq!(0x0004, u16::from(LinuxNonstandardEtherType::N802_2));
        assert_eq!(0x0005, u16::from(LinuxNonstandardEtherType::SNAP));
        assert_eq!(0x0006, u16::from(LinuxNonstandardEtherType::DDCMP));
        assert_eq!(0x0007, u16::from(LinuxNonstandardEtherType::WAN_PPP));
        assert_eq!(0x0008, u16::from(LinuxNonstandardEtherType::PPP_MP));
        assert_eq!(0x0009, u16::from(LinuxNonstandardEtherType::LOCALTALK));
        assert_eq!(0x000C, u16::from(LinuxNonstandardEtherType::CAN));
        assert_eq!(0x000D, u16::from(LinuxNonstandardEtherType::CANFD));
        assert_eq!(0x000E, u16::from(LinuxNonstandardEtherType::CANXL));
        assert_eq!(0x0010, u16::from(LinuxNonstandardEtherType::PPPTALK));
        assert_eq!(0x0011, u16::from(LinuxNonstandardEtherType::TR_802_2));
        assert_eq!(0x0015, u16::from(LinuxNonstandardEtherType::MOBITEX));
        assert_eq!(0x0016, u16::from(LinuxNonstandardEtherType::CONTROL));
        assert_eq!(0x0017, u16::from(LinuxNonstandardEtherType::IRDA));
        assert_eq!(0x0018, u16::from(LinuxNonstandardEtherType::ECONET));
        assert_eq!(0x0019, u16::from(LinuxNonstandardEtherType::HDLC));
        assert_eq!(0x001A, u16::from(LinuxNonstandardEtherType::ARCNET));
        assert_eq!(0x001B, u16::from(LinuxNonstandardEtherType::DSA));
        assert_eq!(0x001C, u16::from(LinuxNonstandardEtherType::TRAILER));
        assert_eq!(0x00F5, u16::from(LinuxNonstandardEtherType::PHONET));
        assert_eq!(0x00F6, u16::from(LinuxNonstandardEtherType::IEEE802154));
        assert_eq!(0x00F7, u16::from(LinuxNonstandardEtherType::CAIF));
        assert_eq!(0x00F8, u16::from(LinuxNonstandardEtherType::XDSA));
        assert_eq!(0x00F9, u16::from(LinuxNonstandardEtherType::MAP));
        assert_eq!(0x00FA, u16::from(LinuxNonstandardEtherType::MCTP));
    }

    #[test]
    fn try_from_u16() {
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0001),
            Ok(LinuxNonstandardEtherType::N802_3)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0002),
            Ok(LinuxNonstandardEtherType::AX25)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0003),
            Ok(LinuxNonstandardEtherType::ALL)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0004),
            Ok(LinuxNonstandardEtherType::N802_2)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0005),
            Ok(LinuxNonstandardEtherType::SNAP)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0006),
            Ok(LinuxNonstandardEtherType::DDCMP)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0007),
            Ok(LinuxNonstandardEtherType::WAN_PPP)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0008),
            Ok(LinuxNonstandardEtherType::PPP_MP)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0009),
            Ok(LinuxNonstandardEtherType::LOCALTALK)
        );
        /* 0x00A..=0x00B */
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x000C),
            Ok(LinuxNonstandardEtherType::CAN)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x000D),
            Ok(LinuxNonstandardEtherType::CANFD)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x000E),
            Ok(LinuxNonstandardEtherType::CANXL)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0010),
            Ok(LinuxNonstandardEtherType::PPPTALK)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0011),
            Ok(LinuxNonstandardEtherType::TR_802_2)
        );
        /* 0x0012..=0x0014 */
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0015),
            Ok(LinuxNonstandardEtherType::MOBITEX)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0016),
            Ok(LinuxNonstandardEtherType::CONTROL)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0017),
            Ok(LinuxNonstandardEtherType::IRDA)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0018),
            Ok(LinuxNonstandardEtherType::ECONET)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x0019),
            Ok(LinuxNonstandardEtherType::HDLC)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x001A),
            Ok(LinuxNonstandardEtherType::ARCNET)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x001B),
            Ok(LinuxNonstandardEtherType::DSA)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x001C),
            Ok(LinuxNonstandardEtherType::TRAILER)
        );
        /* 0x001D..=0x00F4 */
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x00F5),
            Ok(LinuxNonstandardEtherType::PHONET)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x00F6),
            Ok(LinuxNonstandardEtherType::IEEE802154)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x00F7),
            Ok(LinuxNonstandardEtherType::CAIF)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x00F8),
            Ok(LinuxNonstandardEtherType::XDSA)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x00F9),
            Ok(LinuxNonstandardEtherType::MAP)
        );
        assert_eq!(
            LinuxNonstandardEtherType::try_from(0x00FA),
            Ok(LinuxNonstandardEtherType::MCTP)
        );
        /* 0x00FB..=u16::MAX */
    }

    #[test]
    fn dbg() {
        let pairs = &[
            (
                LinuxNonstandardEtherType::N802_3,
                "0x0001 (Dummy type for 802.3 frames)",
            ),
            (
                LinuxNonstandardEtherType::AX25,
                "0x0002 (Dummy protocol id for AX.25)",
            ),
            (LinuxNonstandardEtherType::ALL, "0x0003 (Every packet)"),
            (LinuxNonstandardEtherType::N802_2, "0x0004 (802.2 frames)"),
            (
                LinuxNonstandardEtherType::SNAP,
                "0x0005 (SNAP: Internal only)",
            ),
            (
                LinuxNonstandardEtherType::DDCMP,
                "0x0006 (DEC DDCMP: Internal only)",
            ),
            (
                LinuxNonstandardEtherType::WAN_PPP,
                "0x0007 (Dummy type for WAN PPP frames)",
            ),
            (
                LinuxNonstandardEtherType::PPP_MP,
                "0x0008 (Dummy type for PPP MP frames)",
            ),
            (
                LinuxNonstandardEtherType::LOCALTALK,
                "0x0009 (Localtalk pseudo type)",
            ),
            (
                LinuxNonstandardEtherType::CAN,
                "0x000C (CAN: Controller Area Network)",
            ),
            (
                LinuxNonstandardEtherType::CANFD,
                "0x000D (CANFD: CAN flexible data rate)",
            ),
            (
                LinuxNonstandardEtherType::CANXL,
                "0x000E (CANXL: eXtended frame Length)",
            ),
            (
                LinuxNonstandardEtherType::PPPTALK,
                "0x0010 (Dummy type for Atalk over PPP)",
            ),
            (LinuxNonstandardEtherType::TR_802_2, "0x0011 (802.2 frames)"),
            (LinuxNonstandardEtherType::MOBITEX, "0x0015 (Mobitex)"),
            (
                LinuxNonstandardEtherType::CONTROL,
                "0x0016 (Card specific control frames)",
            ),
            (LinuxNonstandardEtherType::IRDA, "0x0017 (Linux-IrDA)"),
            (LinuxNonstandardEtherType::ECONET, "0x0018 (Acorn Econet)"),
            (LinuxNonstandardEtherType::HDLC, "0x0019 (HDLC frames)"),
            (LinuxNonstandardEtherType::ARCNET, "0x001A (1A for ArcNet)"),
            (
                LinuxNonstandardEtherType::DSA,
                "0x001B (Distributed Switch Arch)",
            ),
            (
                LinuxNonstandardEtherType::TRAILER,
                "0x001C (Trailer switch tagging)",
            ),
            (
                LinuxNonstandardEtherType::PHONET,
                "0x00F5 (Nokia Phonet frame)",
            ),
            (
                LinuxNonstandardEtherType::IEEE802154,
                "0x00F6 (IEEE802.15.4 frame)",
            ),
            (
                LinuxNonstandardEtherType::CAIF,
                "0x00F7 (ST-Ericsson CAIF protocol)",
            ),
            (
                LinuxNonstandardEtherType::XDSA,
                "0x00F8 (Multiplexed DSA protocol)",
            ),
            (
                LinuxNonstandardEtherType::MAP,
                "0x00F9 (Qualcomm multiplexing and aggregation protocol)",
            ),
            (
                LinuxNonstandardEtherType::MCTP,
                "0x00FA (Management component transport protocol packets)",
            ),
        ];

        for (ether_type, str_value) in pairs {
            assert_eq!(str_value, &format!("{:?}", ether_type));
        }
    }

    #[test]
    fn default() {
        let value: LinuxNonstandardEtherType = Default::default();
        assert_eq!(LinuxNonstandardEtherType::N802_3, value);
    }

    #[test]
    fn clone_eq() {
        let values = &[
            LinuxNonstandardEtherType::N802_3,
            LinuxNonstandardEtherType::AX25,
            LinuxNonstandardEtherType::ALL,
            LinuxNonstandardEtherType::N802_2,
            LinuxNonstandardEtherType::SNAP,
            LinuxNonstandardEtherType::DDCMP,
            LinuxNonstandardEtherType::WAN_PPP,
            LinuxNonstandardEtherType::PPP_MP,
            LinuxNonstandardEtherType::LOCALTALK,
            LinuxNonstandardEtherType::CAN,
            LinuxNonstandardEtherType::CANFD,
            LinuxNonstandardEtherType::CANXL,
            LinuxNonstandardEtherType::PPPTALK,
            LinuxNonstandardEtherType::TR_802_2,
            LinuxNonstandardEtherType::MOBITEX,
            LinuxNonstandardEtherType::CONTROL,
            LinuxNonstandardEtherType::IRDA,
            LinuxNonstandardEtherType::ECONET,
            LinuxNonstandardEtherType::HDLC,
            LinuxNonstandardEtherType::ARCNET,
            LinuxNonstandardEtherType::DSA,
            LinuxNonstandardEtherType::TRAILER,
            LinuxNonstandardEtherType::PHONET,
            LinuxNonstandardEtherType::IEEE802154,
            LinuxNonstandardEtherType::CAIF,
            LinuxNonstandardEtherType::XDSA,
            LinuxNonstandardEtherType::MAP,
            LinuxNonstandardEtherType::MCTP,
        ];

        // clone
        for v in values {
            assert_eq!(v, &v.clone());
        }

        // eq
        for (a_pos, a) in values.iter().enumerate() {
            for (b_pos, b) in values.iter().enumerate() {
                assert_eq!(a_pos == b_pos, a == b);
                assert_eq!(a_pos != b_pos, a != b);
            }
        }
    }
}
