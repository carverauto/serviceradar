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
