use crate::converter::Converter;
use crate::converter::flowpb;
use netflow_parser::NetflowPacket;

#[derive(Debug)]
pub enum GetCurrentTimeError {
    SystemTimeError(std::time::SystemTimeError),
    TryFromIntError(std::num::TryFromIntError),
}

impl std::fmt::Display for GetCurrentTimeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GetCurrentTimeError::SystemTimeError(e) => {
                write!(f, "System time error: {}", e)
            }
            GetCurrentTimeError::TryFromIntError(e) => {
                write!(f, "Integer conversion error: {}", e)
            }
        }
    }
}

impl std::error::Error for GetCurrentTimeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            GetCurrentTimeError::SystemTimeError(e) => Some(e),
            GetCurrentTimeError::TryFromIntError(e) => Some(e),
        }
    }
}

#[derive(Debug)]
pub enum ConversionError {
    NoGeneratedMessages,
}

impl TryFrom<Converter> for Vec<flowpb::FlowMessage> {
    type Error = ConversionError;

    fn try_from(converter: Converter) -> Result<Self, Self::Error> {
        match converter.packet {
            NetflowPacket::V5(ref v5) => converter.convert_v5(v5),
            NetflowPacket::V7(_) => Ok(vec![]),
            NetflowPacket::V9(ref v9) => converter.convert_v9(v9),
            NetflowPacket::IPFix(ref ipfix) => converter.convert_ipfix(ipfix),
        }
    }
}
