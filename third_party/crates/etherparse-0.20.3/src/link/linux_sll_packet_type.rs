use core::hint::unreachable_unchecked;

use crate::err::{self};

/// Represents an "Packet type", indicating the direction where it was sent,
/// used inside a SLL header
///
/// You can convert `u16` in the valid range to an `LinuxSllType` and the
/// other way around
///
/// ```
/// use etherparse::LinuxSllPacketType;
///
/// // Convert to LinuxSllPacketType using the try_from & try_into trait
/// let link_type: LinuxSllPacketType = 1_u16.try_into().unwrap();
/// assert_eq!(LinuxSllPacketType::BROADCAST, link_type);
///
/// // convert to u16 using the from & into trait
/// let num: u16 = LinuxSllPacketType::BROADCAST.into();
/// assert_eq!(1, num);
/// ```
#[derive(Clone, Copy, Eq, PartialEq, Default)]
pub struct LinuxSllPacketType(u16);

impl LinuxSllPacketType {
    // Numbers sourced from https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/include/uapi/linux/if_packet.h?id=e33c4963bf536900f917fb65a687724d5539bc21

    pub const HOST: LinuxSllPacketType = Self(0);
    pub const BROADCAST: LinuxSllPacketType = Self(1);
    pub const MULTICAST: LinuxSllPacketType = Self(2);
    pub const OTHERHOST: LinuxSllPacketType = Self(3);
    pub const OUTGOING: LinuxSllPacketType = Self(4);
    pub const LOOPBACK: LinuxSllPacketType = Self(5);
    pub const USER: LinuxSllPacketType = Self(6);
    pub const KERNEL: LinuxSllPacketType = Self(7);

    pub const MAX_VAL: u16 = 7;
    const FIRST_INVALID: u16 = LinuxSllPacketType::MAX_VAL + 1;
}

impl TryFrom<u16> for LinuxSllPacketType {
    type Error = err::linux_sll::HeaderError;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(LinuxSllPacketType::HOST),
            1 => Ok(LinuxSllPacketType::BROADCAST),
            2 => Ok(LinuxSllPacketType::MULTICAST),
            3 => Ok(LinuxSllPacketType::OTHERHOST),
            4 => Ok(LinuxSllPacketType::OUTGOING),
            5 => Ok(LinuxSllPacketType::LOOPBACK),
            6 => Ok(LinuxSllPacketType::USER),
            7 => Ok(LinuxSllPacketType::KERNEL),
            LinuxSllPacketType::FIRST_INVALID..=u16::MAX => {
                Err(err::linux_sll::HeaderError::UnsupportedPacketTypeField { packet_type: value })
            }
        }
    }
}

impl From<LinuxSllPacketType> for u16 {
    #[inline]
    fn from(val: LinuxSllPacketType) -> Self {
        val.0
    }
}

impl core::fmt::Debug for LinuxSllPacketType {
    // Descriptions sourced from https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/include/uapi/linux/if_packet.h?id=e33c4963bf536900f917fb65a687724d5539bc21

    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self.0 {
            0 => write!(f, "0 (Sent to us)"),
            1 => write!(f, "1 (Sent to all)"),
            2 => write!(f, "2 (Sent to group)"),
            3 => write!(f, "3 (Sent to someone else)"),
            4 => write!(f, "4 (Sent by us)"),
            5 => write!(f, "5 (MC/BRD frame looped back)"),
            6 => write!(f, "6 (Sent to user space)"),
            7 => write!(f, "7 (Sent to kernel space)"),
            LinuxSllPacketType::FIRST_INVALID..=u16::MAX => {
                // SAFETY:
                // Safe because values over MAX_VAL/FIRST_INVALID are never constructed
                unsafe { unreachable_unchecked() }
            }
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use alloc::format;

    #[test]
    fn to_u16() {
        assert_eq!(0, u16::from(LinuxSllPacketType::HOST));
        assert_eq!(1, u16::from(LinuxSllPacketType::BROADCAST));
        assert_eq!(2, u16::from(LinuxSllPacketType::MULTICAST));
        assert_eq!(3, u16::from(LinuxSllPacketType::OTHERHOST));
        assert_eq!(4, u16::from(LinuxSllPacketType::OUTGOING));
        assert_eq!(5, u16::from(LinuxSllPacketType::LOOPBACK));
        assert_eq!(6, u16::from(LinuxSllPacketType::USER));
        assert_eq!(7, u16::from(LinuxSllPacketType::KERNEL));
    }

    #[test]
    fn try_from_u16() {
        assert_eq!(
            LinuxSllPacketType::try_from(0),
            Ok(LinuxSllPacketType::HOST)
        );
        assert_eq!(
            LinuxSllPacketType::try_from(1),
            Ok(LinuxSllPacketType::BROADCAST)
        );
        assert_eq!(
            LinuxSllPacketType::try_from(2),
            Ok(LinuxSllPacketType::MULTICAST)
        );
        assert_eq!(
            LinuxSllPacketType::try_from(3),
            Ok(LinuxSllPacketType::OTHERHOST)
        );
        assert_eq!(
            LinuxSllPacketType::try_from(4),
            Ok(LinuxSllPacketType::OUTGOING)
        );
        assert_eq!(
            LinuxSllPacketType::try_from(5),
            Ok(LinuxSllPacketType::LOOPBACK)
        );
        assert_eq!(
            LinuxSllPacketType::try_from(6),
            Ok(LinuxSllPacketType::USER)
        );
        assert_eq!(
            LinuxSllPacketType::try_from(7),
            Ok(LinuxSllPacketType::KERNEL)
        );
        assert_eq!(
            LinuxSllPacketType::try_from(8),
            Err(err::linux_sll::HeaderError::UnsupportedPacketTypeField { packet_type: 8 })
        );
        assert_eq!(
            LinuxSllPacketType::try_from(123),
            Err(err::linux_sll::HeaderError::UnsupportedPacketTypeField { packet_type: 123 })
        );
    }

    #[test]
    fn dbg() {
        let pairs = &[
            (LinuxSllPacketType::HOST, "0 (Sent to us)"),
            (LinuxSllPacketType::BROADCAST, "1 (Sent to all)"),
            (LinuxSllPacketType::MULTICAST, "2 (Sent to group)"),
            (LinuxSllPacketType::OTHERHOST, "3 (Sent to someone else)"),
            (LinuxSllPacketType::OUTGOING, "4 (Sent by us)"),
            (LinuxSllPacketType::LOOPBACK, "5 (MC/BRD frame looped back)"),
            (LinuxSllPacketType::USER, "6 (Sent to user space)"),
            (LinuxSllPacketType::KERNEL, "7 (Sent to kernel space)"),
        ];

        for (ether_type, str_value) in pairs {
            assert_eq!(str_value, &format!("{:?}", ether_type));
        }
    }

    #[test]
    fn default() {
        let value: LinuxSllPacketType = Default::default();
        assert_eq!(LinuxSllPacketType::HOST, value);
    }

    #[test]
    fn clone_eq() {
        let values = &[
            LinuxSllPacketType::HOST,
            LinuxSllPacketType::BROADCAST,
            LinuxSllPacketType::MULTICAST,
            LinuxSllPacketType::OTHERHOST,
            LinuxSllPacketType::OUTGOING,
            LinuxSllPacketType::LOOPBACK,
            LinuxSllPacketType::USER,
            LinuxSllPacketType::KERNEL,
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
