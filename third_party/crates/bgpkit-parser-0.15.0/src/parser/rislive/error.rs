use std::convert;
use std::error::Error;
use std::fmt::{Display, Formatter};

#[derive(Debug)]
pub enum ParserRisliveError {
    IncorrectJson(String),
    IncorrectRawBytes,
    IrregularRisLiveFormat,
    UnsupportedMessage,
    ElemEndOfRibPrefix,
    ElemUnknownOriginType(String),
    ElemIncorrectAggregator(String),
    ElemIncorrectPrefix(String),
    ElemIncorrectIp(String),
}

impl Display for ParserRisliveError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            ParserRisliveError::IncorrectJson(msg) => {
                write!(f, "incorrect json message: {msg}")
            }
            ParserRisliveError::IncorrectRawBytes => {
                write!(f, "incorrect raw bytes")
            }
            ParserRisliveError::UnsupportedMessage => {
                write!(f, "unsupported message")
            }
            ParserRisliveError::IrregularRisLiveFormat => {
                write!(f, "irregular ris live format")
            }
            ParserRisliveError::ElemIncorrectPrefix(msg) => {
                write!(f, "incorrect prefix string: {msg}")
            }
            ParserRisliveError::ElemUnknownOriginType(msg) => {
                write!(f, "unknown origin type: {msg}")
            }
            ParserRisliveError::ElemIncorrectAggregator(msg) => {
                write!(f, "incorrect aggregator string: {msg}")
            }
            ParserRisliveError::ElemIncorrectIp(msg) => {
                write!(f, "incorrect IP string: {msg}")
            }
            ParserRisliveError::ElemEndOfRibPrefix => {
                write!(f, "found 'eor' (End of RIB) prefix")
            }
        }
    }
}

impl convert::From<serde_json::Error> for ParserRisliveError {
    fn from(_: serde_json::Error) -> Self {
        ParserRisliveError::IncorrectJson("serde_json error".to_string())
    }
}

impl Error for ParserRisliveError {}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[test]
    fn test_convert_from_serde_json_error() {
        #[derive(Deserialize)]
        struct TestError;

        let json: Result<TestError, _> = serde_json::from_str("test");
        let err = ParserRisliveError::from(json.err().unwrap());
        assert_eq!(err.to_string(), "incorrect json message: serde_json error");
    }

    #[test]
    fn test_ris_live_error_display() {
        let err = ParserRisliveError::IncorrectJson("test".to_string());
        assert_eq!(err.to_string(), "incorrect json message: test");

        let err = ParserRisliveError::IncorrectRawBytes;
        assert_eq!(err.to_string(), "incorrect raw bytes");

        let err = ParserRisliveError::UnsupportedMessage;
        assert_eq!(err.to_string(), "unsupported message");

        let err = ParserRisliveError::IrregularRisLiveFormat;
        assert_eq!(err.to_string(), "irregular ris live format");

        let err = ParserRisliveError::ElemIncorrectPrefix("test".to_string());
        assert_eq!(err.to_string(), "incorrect prefix string: test");

        let err = ParserRisliveError::ElemUnknownOriginType("test".to_string());
        assert_eq!(err.to_string(), "unknown origin type: test");

        let err = ParserRisliveError::ElemIncorrectAggregator("test".to_string());
        assert_eq!(err.to_string(), "incorrect aggregator string: test");

        let err = ParserRisliveError::ElemIncorrectIp("test".to_string());
        assert_eq!(err.to_string(), "incorrect IP string: test");

        let err = ParserRisliveError::ElemEndOfRibPrefix;
        assert_eq!(err.to_string(), "found 'eor' (End of RIB) prefix");
    }
    #[test]
    fn test_ris_live_error_debug() {
        let err = ParserRisliveError::IncorrectJson("test".to_string());
        assert_eq!(format!("{err:?}"), "IncorrectJson(\"test\")");

        let err = ParserRisliveError::IncorrectRawBytes;
        assert_eq!(format!("{err:?}"), "IncorrectRawBytes");

        let err = ParserRisliveError::UnsupportedMessage;
        assert_eq!(format!("{err:?}"), "UnsupportedMessage");

        let err = ParserRisliveError::IrregularRisLiveFormat;
        assert_eq!(format!("{err:?}"), "IrregularRisLiveFormat");

        let err = ParserRisliveError::ElemIncorrectPrefix("test".to_string());
        assert_eq!(format!("{err:?}"), "ElemIncorrectPrefix(\"test\")");

        let err = ParserRisliveError::ElemUnknownOriginType("test".to_string());
        assert_eq!(format!("{err:?}"), "ElemUnknownOriginType(\"test\")");

        let err = ParserRisliveError::ElemIncorrectAggregator("test".to_string());
        assert_eq!(format!("{err:?}"), "ElemIncorrectAggregator(\"test\")");

        let err = ParserRisliveError::ElemIncorrectIp("test".to_string());
        assert_eq!(format!("{err:?}"), "ElemIncorrectIp(\"test\")");

        let err = ParserRisliveError::ElemEndOfRibPrefix;
        assert_eq!(format!("{err:?}"), "ElemEndOfRibPrefix");
    }
}
