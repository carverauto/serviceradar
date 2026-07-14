use num_enum::{IntoPrimitive, TryFromPrimitive};
use std::fmt::{Display, Formatter};

#[allow(non_camel_case_types)]
#[derive(Debug, TryFromPrimitive, IntoPrimitive, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum Origin {
    /// Interior Gateway Protocol
    IGP = 0,
    /// Exterior Gateway Protocol
    /// <https://datatracker.ietf.org/doc/html/rfc904>
    EGP = 1,
    INCOMPLETE = 2,
}

impl Display for Origin {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Origin::IGP => write!(f, "IGP"),
            Origin::EGP => write!(f, "EGP"),
            Origin::INCOMPLETE => write!(f, "INCOMPLETE"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(feature = "serde")]
    fn test_serde() {
        use serde_json;

        let origin = Origin::IGP;
        let serialized = serde_json::to_string(&origin).unwrap();
        let deserialized: Origin = serde_json::from_str(&serialized).unwrap();
        assert_eq!(origin, deserialized);

        let origin = Origin::EGP;
        let serialized = serde_json::to_string(&origin).unwrap();
        let deserialized: Origin = serde_json::from_str(&serialized).unwrap();
        assert_eq!(origin, deserialized);

        let origin = Origin::INCOMPLETE;
        let serialized = serde_json::to_string(&origin).unwrap();
        let deserialized: Origin = serde_json::from_str(&serialized).unwrap();
        assert_eq!(origin, deserialized);
    }

    #[test]
    fn test_display() {
        let origin = Origin::IGP;
        assert_eq!(format!("{origin}"), "IGP");
        let origin = Origin::EGP;
        assert_eq!(format!("{origin}"), "EGP");
        let origin = Origin::INCOMPLETE;
        assert_eq!(format!("{origin}"), "INCOMPLETE");
    }
}
