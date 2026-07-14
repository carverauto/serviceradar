//! BGP error code module that maintains explicit error codes assigned by IANA.
//!
//! The full list of IANA error code assignments for BGP can be viewed at here:
//! <https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-3>.
use log::warn;
use num_enum::{FromPrimitive, IntoPrimitive};

#[derive(Copy, Clone, Debug, FromPrimitive, IntoPrimitive)]
#[repr(u8)]
pub enum BgpErrorCode {
    Reserved = 0,
    MessageHeaderError = 1,
    OpenError = 2,
    UpdateError = 3,
    HoldTimerExpired = 4,
    FiniteStateMachineError = 5,
    CeaseNotification = 6,
    RouteFreshError = 7,
    #[num_enum(catch_all)]
    Unknown(u8),
}

/// BGP Error Subcode enum.
///
/// <https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-4>
#[allow(non_camel_case_types)]
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum BgpError {
    /// Includes subcode. Currently, no subcodes have been assigned.
    Reserved(u8),
    MessageHeaderError(MessageHeaderError),
    OpenError(OpenError),
    UpdateError(UpdateError),
    /// Includes subcode. Currently, no subcodes have been assigned.
    HoldTimerExpired(u8),
    FiniteStateMachineError(FiniteStateMachineError),
    CeaseNotification(CeaseNotification),
    RouteFreshError(RouteRefreshError),
    Unknown(u8, u8),
}

impl BgpError {
    pub fn new(code: u8, subcode: u8) -> Self {
        match BgpErrorCode::from(code) {
            BgpErrorCode::Reserved => BgpError::Reserved(subcode),
            BgpErrorCode::MessageHeaderError => {
                BgpError::MessageHeaderError(MessageHeaderError::from(subcode))
            }
            BgpErrorCode::OpenError => BgpError::OpenError(OpenError::from(subcode)),
            BgpErrorCode::UpdateError => BgpError::UpdateError(UpdateError::from(subcode)),
            BgpErrorCode::HoldTimerExpired => BgpError::HoldTimerExpired(subcode),
            BgpErrorCode::FiniteStateMachineError => {
                BgpError::FiniteStateMachineError(FiniteStateMachineError::from(subcode))
            }
            BgpErrorCode::CeaseNotification => {
                BgpError::CeaseNotification(CeaseNotification::from(subcode))
            }
            BgpErrorCode::RouteFreshError => {
                BgpError::RouteFreshError(RouteRefreshError::from(subcode))
            }
            BgpErrorCode::Unknown(_) => {
                warn!(
                    "error parsing BGP notification error code: {}, subcode: {}",
                    code, subcode
                );
                BgpError::Unknown(code, subcode)
            }
        }
    }

    pub fn get_codes(&self) -> (u8, u8) {
        match self {
            BgpError::Reserved(code) => (0, *code),
            BgpError::MessageHeaderError(v) => (1, (*v).into()),
            BgpError::OpenError(v) => (2, (*v).into()),
            BgpError::UpdateError(v) => (3, (*v).into()),
            BgpError::HoldTimerExpired(v) => (4, *v),
            BgpError::FiniteStateMachineError(v) => (5, (*v).into()),
            BgpError::CeaseNotification(v) => (6, (*v).into()),
            BgpError::RouteFreshError(v) => (7, (*v).into()),
            BgpError::Unknown(code, subcode) => (*code, *subcode),
        }
    }
}

/// Message Header Error subcodes
///
/// <https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-5>
///
/// *See source code for number assignment*
#[allow(non_camel_case_types)]
#[derive(Debug, FromPrimitive, IntoPrimitive, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum MessageHeaderError {
    UNSPECIFIC = 0,
    CONNECTION_NOT_SYNCHRONIZED = 1,
    BAD_MESSAGE_LENGTH = 2,
    BAD_MESSAGE_TYPE = 3,
    // 4 - 255: unassigned
    #[num_enum(catch_all)]
    Unknown(u8),
}

/// OPEN Message Error subcodes
///
/// <https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-6>
///
/// *See source code for number assignment*
#[allow(non_camel_case_types)]
#[derive(Debug, FromPrimitive, IntoPrimitive, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum OpenError {
    UNSPECIFIC = 0,
    UNSUPPORTED_VERSION_NUMBER = 1,
    BAD_PEER_AS = 2,
    BAD_BGP_IDENTIFIER = 3,
    UNSUPPORTED_OPTIONAL_PARAMETER = 4,
    // 5 -- deprecated
    UNACCEPTABLE_HOLD_TIME = 6,
    UNSUPPORTED_CAPACITY = 7,
    // 8 -- deprecated
    // 9 -- deprecated
    // 10 -- deprecated
    ROLE_MISMATCH = 11,
    // 12 - 255: unassinged
    #[num_enum(catch_all)]
    Unknown(u8),
}

impl OpenError {
    pub const fn is_deprecated(&self) -> bool {
        matches!(self, OpenError::Unknown(5 | 8 | 9 | 10))
    }
}

/// UPDATE Message Error subcodes
///
/// <https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-finite-state-machine-error-subcodes>
///
/// *See source code for number assignment*
#[allow(non_camel_case_types)]
#[derive(Debug, FromPrimitive, IntoPrimitive, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum UpdateError {
    UNSPECIFIC = 0,
    MALFORMED_ATTRIBUTE_LIST = 1,
    UNRECOGNIZED_WELL_KNOWN_ATTRIBUTE = 2,
    MISSING_WELL_KNOWN_ATTRIBUTE = 3,
    ATTRIBUTE_FLAGS_ERROR = 4,
    ATTRIBUTE_LENGTH_ERROR = 5,
    INVALID_ORIGIN_ERROR = 6,
    // 7 - deprecated
    INVALID_NEXT_HOP_ATTRIBUTE = 8,
    OPTIONAL_ATTRIBUTE_ERROR = 9,
    INVALID_NETWORK_FIELD = 10,
    MALFORMED_AS_PATH = 11,
    // 12 - 255: unassigned
    #[num_enum(catch_all)]
    Unknown(u8),
}

impl UpdateError {
    pub const fn is_deprecated(&self) -> bool {
        matches!(self, UpdateError::Unknown(7))
    }
}

/// BGP Finite State Machine Error Subcodes
///
/// <https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-finite-state-machine-error-subcodes>
///
/// *See source code for number assignment*
#[allow(non_camel_case_types)]
#[derive(Debug, FromPrimitive, IntoPrimitive, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum FiniteStateMachineError {
    UNSPECIFIED = 0,
    RECEIVE_UNEXPECTED_MESSAGE_IN_OPENSENT_State = 1,
    RECEIVE_UNEXPECTED_MESSAGE_IN_OPENCONFIRM_STATE = 2,
    RECEIVE_UNEXPECTED_MESSAGE_IN_ESTABLISHED_STATE = 3,
    // 4 - 255: unassigned
    #[num_enum(catch_all)]
    Unknown(u8),
}

/// BGP Cease NOTIFICATION message subcodes
///
/// <https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-8>
///
/// *See source code for number assignment*
#[allow(non_camel_case_types)]
#[derive(Debug, FromPrimitive, IntoPrimitive, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum CeaseNotification {
    RESERVED = 0,
    MAXIMUM_NUMBER_OF_PREFIXES_REACHED = 1,
    ADMINISTRATIVE_SHUTDOWN = 2,
    PEER_DE_CONFIGURED = 3,
    ADMINISTRATIVE_RESET = 4,
    CONNECTION_REJECTED = 5,
    OTHER_CONFIGURATION_CHANGE = 6,
    CONNECTION_COLLISION_RESOLUTION = 7,
    OUT_OF_RESOURCES = 8,
    HARD_RESET = 9,
    BFD_DOWN = 10, // TEMPORARY - registered 2022-02-23, expires 2023-02-23
    // 11 - 255: unassigned
    #[num_enum(catch_all)]
    Unknown(u8),
}

/// BGP ROUTE-REFRESH Message Error subcodes
///
/// <https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#route-refresh-error-subcodes>
///
/// *See source code for number assignment*
#[allow(non_camel_case_types)]
#[derive(Debug, FromPrimitive, IntoPrimitive, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum RouteRefreshError {
    RESERVED = 0,
    INVALID_MESSAGE_LENGTH = 1,
    // 2 - 255: unassigned
    #[num_enum(catch_all)]
    Unknown(u8),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parsing() {
        assert_eq!(BgpError::new(0, 0), BgpError::Reserved(0));

        assert_eq!(
            BgpError::new(1, 0),
            BgpError::MessageHeaderError(MessageHeaderError::UNSPECIFIC)
        );
        assert_eq!(
            BgpError::new(1, 1),
            BgpError::MessageHeaderError(MessageHeaderError::CONNECTION_NOT_SYNCHRONIZED)
        );
        assert_eq!(
            BgpError::new(1, 2),
            BgpError::MessageHeaderError(MessageHeaderError::BAD_MESSAGE_LENGTH)
        );
        assert_eq!(
            BgpError::new(1, 3),
            BgpError::MessageHeaderError(MessageHeaderError::BAD_MESSAGE_TYPE)
        );
        assert_eq!(
            BgpError::new(1, 4),
            BgpError::MessageHeaderError(MessageHeaderError::Unknown(4)),
        );

        assert_eq!(
            BgpError::new(2, 0),
            BgpError::OpenError(OpenError::UNSPECIFIC)
        );
        assert_eq!(
            BgpError::new(2, 1),
            BgpError::OpenError(OpenError::UNSUPPORTED_VERSION_NUMBER)
        );
        assert_eq!(
            BgpError::new(2, 2),
            BgpError::OpenError(OpenError::BAD_PEER_AS)
        );
        assert_eq!(
            BgpError::new(2, 3),
            BgpError::OpenError(OpenError::BAD_BGP_IDENTIFIER)
        );
        assert_eq!(
            BgpError::new(2, 4),
            BgpError::OpenError(OpenError::UNSUPPORTED_OPTIONAL_PARAMETER)
        );
        assert_eq!(
            BgpError::new(2, 6),
            BgpError::OpenError(OpenError::UNACCEPTABLE_HOLD_TIME)
        );
        assert_eq!(
            BgpError::new(2, 7),
            BgpError::OpenError(OpenError::UNSUPPORTED_CAPACITY)
        );
        assert_eq!(
            BgpError::new(2, 11),
            BgpError::OpenError(OpenError::ROLE_MISMATCH)
        );
        // deprecated subcodes
        for n in [5, 8, 9, 10] {
            assert_eq!(
                BgpError::new(2, n),
                BgpError::OpenError(OpenError::Unknown(n))
            );
            assert!(OpenError::Unknown(n).is_deprecated());
        }
        assert_eq!(
            BgpError::new(2, 12),
            BgpError::OpenError(OpenError::Unknown(12))
        );

        assert_eq!(
            BgpError::new(3, 0),
            BgpError::UpdateError(UpdateError::UNSPECIFIC)
        );
        assert_eq!(
            BgpError::new(3, 1),
            BgpError::UpdateError(UpdateError::MALFORMED_ATTRIBUTE_LIST)
        );
        assert_eq!(
            BgpError::new(3, 2),
            BgpError::UpdateError(UpdateError::UNRECOGNIZED_WELL_KNOWN_ATTRIBUTE)
        );
        assert_eq!(
            BgpError::new(3, 3),
            BgpError::UpdateError(UpdateError::MISSING_WELL_KNOWN_ATTRIBUTE)
        );
        assert_eq!(
            BgpError::new(3, 4),
            BgpError::UpdateError(UpdateError::ATTRIBUTE_FLAGS_ERROR)
        );
        assert_eq!(
            BgpError::new(3, 5),
            BgpError::UpdateError(UpdateError::ATTRIBUTE_LENGTH_ERROR)
        );
        assert_eq!(
            BgpError::new(3, 6),
            BgpError::UpdateError(UpdateError::INVALID_ORIGIN_ERROR)
        );
        assert_eq!(
            BgpError::new(3, 8),
            BgpError::UpdateError(UpdateError::INVALID_NEXT_HOP_ATTRIBUTE)
        );
        assert_eq!(
            BgpError::new(3, 9),
            BgpError::UpdateError(UpdateError::OPTIONAL_ATTRIBUTE_ERROR)
        );
        assert_eq!(
            BgpError::new(3, 10),
            BgpError::UpdateError(UpdateError::INVALID_NETWORK_FIELD)
        );
        assert_eq!(
            BgpError::new(3, 11),
            BgpError::UpdateError(UpdateError::MALFORMED_AS_PATH)
        );
        // deprecated subcodes
        assert_eq!(
            BgpError::new(3, 7),
            BgpError::UpdateError(UpdateError::Unknown(7))
        );
        assert!(UpdateError::Unknown(7).is_deprecated());

        assert_eq!(
            BgpError::new(3, 12),
            BgpError::UpdateError(UpdateError::Unknown(12))
        );

        assert_eq!(BgpError::new(4, 0), BgpError::HoldTimerExpired(0));
        // subcode should not matter here
        assert_eq!(BgpError::new(4, 1), BgpError::HoldTimerExpired(1));

        assert_eq!(
            BgpError::new(5, 0),
            BgpError::FiniteStateMachineError(FiniteStateMachineError::UNSPECIFIED)
        );
        assert_eq!(
            BgpError::new(5, 1),
            BgpError::FiniteStateMachineError(
                FiniteStateMachineError::RECEIVE_UNEXPECTED_MESSAGE_IN_OPENSENT_State
            )
        );
        assert_eq!(
            BgpError::new(5, 2),
            BgpError::FiniteStateMachineError(
                FiniteStateMachineError::RECEIVE_UNEXPECTED_MESSAGE_IN_OPENCONFIRM_STATE
            )
        );
        assert_eq!(
            BgpError::new(5, 3),
            BgpError::FiniteStateMachineError(
                FiniteStateMachineError::RECEIVE_UNEXPECTED_MESSAGE_IN_ESTABLISHED_STATE
            )
        );
        assert_eq!(
            BgpError::new(5, 4),
            BgpError::FiniteStateMachineError(FiniteStateMachineError::Unknown(4))
        );

        assert_eq!(
            BgpError::new(6, 0),
            BgpError::CeaseNotification(CeaseNotification::RESERVED)
        );
        assert_eq!(
            BgpError::new(6, 1),
            BgpError::CeaseNotification(CeaseNotification::MAXIMUM_NUMBER_OF_PREFIXES_REACHED)
        );
        assert_eq!(
            BgpError::new(6, 2),
            BgpError::CeaseNotification(CeaseNotification::ADMINISTRATIVE_SHUTDOWN)
        );
        assert_eq!(
            BgpError::new(6, 3),
            BgpError::CeaseNotification(CeaseNotification::PEER_DE_CONFIGURED)
        );
        assert_eq!(
            BgpError::new(6, 4),
            BgpError::CeaseNotification(CeaseNotification::ADMINISTRATIVE_RESET)
        );
        assert_eq!(
            BgpError::new(6, 5),
            BgpError::CeaseNotification(CeaseNotification::CONNECTION_REJECTED)
        );
        assert_eq!(
            BgpError::new(6, 6),
            BgpError::CeaseNotification(CeaseNotification::OTHER_CONFIGURATION_CHANGE)
        );
        assert_eq!(
            BgpError::new(6, 7),
            BgpError::CeaseNotification(CeaseNotification::CONNECTION_COLLISION_RESOLUTION)
        );
        assert_eq!(
            BgpError::new(6, 8),
            BgpError::CeaseNotification(CeaseNotification::OUT_OF_RESOURCES)
        );
        assert_eq!(
            BgpError::new(6, 9),
            BgpError::CeaseNotification(CeaseNotification::HARD_RESET)
        );
        assert_eq!(
            BgpError::new(6, 10),
            BgpError::CeaseNotification(CeaseNotification::BFD_DOWN)
        );
        assert_eq!(
            BgpError::new(6, 11),
            BgpError::CeaseNotification(CeaseNotification::Unknown(11))
        );

        assert_eq!(
            BgpError::new(7, 0),
            BgpError::RouteFreshError(RouteRefreshError::RESERVED)
        );
        assert_eq!(
            BgpError::new(7, 1),
            BgpError::RouteFreshError(RouteRefreshError::INVALID_MESSAGE_LENGTH)
        );
        assert_eq!(
            BgpError::new(7, 2),
            BgpError::RouteFreshError(RouteRefreshError::Unknown(2))
        );

        assert_eq!(BgpError::new(8, 2), BgpError::Unknown(8, 2));
    }
}
