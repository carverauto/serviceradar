// There are four ranges:
// First Interindustry   0b000x_xxxx
// Further Interindustry 0b01xx_xxxx
// Reserved              0b001x_xxxx
// Proprietary           0b1xxx_xxxx
//
// For the interindustry ranges, class contains:
// - chaining (continues/last)
// - secure messaging indication (none, two standard, proprietary)
// - logical channel number

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct Class {
    cla: u8,
    range: Range,
    // secure_messaging: SecureMessaging,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum SecureMessaging {
    None = 0,
    Proprietary = 1,
    Standard = 2,
    Authenticated = 3,
    Unknown,
}

impl SecureMessaging {
    pub fn none(&self) -> bool {
        *self == SecureMessaging::None
    }
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum Chain {
    LastOrOnly,
    NotTheLast,
    Unknown,
}

impl Chain {
    #[inline]
    pub fn last_or_only(&self) -> bool {
        *self == Chain::LastOrOnly
    }

    #[inline]
    pub fn not_the_last(&self) -> bool {
        *self == Chain::NotTheLast
    }
}

impl Class {
    #[inline]
    pub const fn into_inner(self) -> u8 {
        self.cla
    }

    #[inline]
    pub const fn range(&self) -> Range {
        self.range
    }

    #[inline]
    pub const fn secure_messaging(&self) -> SecureMessaging {
        match self.range {
            Range::Interindustry(which) => match which {
                Interindustry::First => match (self.cla >> 2) & 0b11 {
                    0b00 => SecureMessaging::None,
                    0b01 => SecureMessaging::Proprietary,
                    0b10 => SecureMessaging::Standard,
                    0b11 => SecureMessaging::Authenticated,
                    _ => unreachable!(),
                },
                Interindustry::Further => match (self.cla >> 5) != 0 {
                    true => SecureMessaging::Standard,
                    false => SecureMessaging::None,
                },
                Interindustry::Reserved => SecureMessaging::Unknown,
            },
            _ => SecureMessaging::Unknown,
        }
    }

    #[inline]
    pub const fn chain(&self) -> Chain {
        if self.cla & (1 << 4) != 0 {
            Chain::NotTheLast
        } else {
            Chain::LastOrOnly
        }
    }

    pub const fn as_chained(mut self) -> Self {
        self.cla |= 1 << 4;
        self
    }

    #[inline]
    pub const fn channel(&self) -> Option<u8> {
        Some(match self.range {
            Range::Interindustry(Interindustry::First) => self.cla & 0b11,
            Range::Interindustry(Interindustry::Further) => (4 + self.cla) & 0b111,
            _ => return None,
        })
    }

    pub const fn from_byte(cla: u8) -> Result<Self, InvalidClass> {
        match Range::from_cla(cla) {
            Ok(range) => Ok(Self { cla, range }),
            Err(err) => Err(err),
        }
    }
}

impl TryFrom<u8> for Class {
    type Error = InvalidClass;

    #[inline]
    fn try_from(cla: u8) -> Result<Self, Self::Error> {
        let range = Range::try_from(cla)?;
        Ok(Self { cla, range })
    }
}

// impl core::ops::Deref for Class {
//     type Target = u8;
//     fn deref(&self) -> &Self::Target {
//         &self.cla
//     }
// }

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum Range {
    Interindustry(Interindustry),
    Proprietary,
}

impl Range {
    pub const fn from_cla(cla: u8) -> Result<Self, InvalidClass> {
        if cla == 0xff {
            return Err(InvalidClass {});
        }

        let range = match cla >> 5 {
            0b000 => Range::Interindustry(Interindustry::First),
            0b010 | 0b011 => Range::Interindustry(Interindustry::Further),
            0b001 => Range::Interindustry(Interindustry::Reserved),
            _ => Range::Proprietary,
        };

        Ok(range)
    }
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum Interindustry {
    First,
    Further,
    Reserved,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct InvalidClass {}

impl TryFrom<u8> for Range {
    type Error = InvalidClass;

    #[inline]
    fn try_from(cla: u8) -> Result<Self, Self::Error> {
        Self::from_cla(cla)
    }
}

pub const ZERO_CLA: Class = match Class::from_byte(0x00) {
    Ok(cla) => cla,
    Err(_) => unreachable!(),
};

/// Cla = 0x80
pub const NO_SM_CLA: Class = match Class::from_byte(0x80) {
    Ok(cla) => cla,
    Err(_) => unreachable!(),
};

/// Cla = 0x84
pub const SM_CLA: Class = match Class::from_byte(0x84) {
    Ok(cla) => cla,
    Err(_) => unreachable!(),
};
