use thiserror::Error;

#[derive(Error, Debug)]
#[non_exhaustive]
pub enum S3Error {
    #[error("Utf8 decoding error: {0}")]
    Utf8(#[from] std::str::Utf8Error),
    #[error("Max expiration for presigned URLs is one week, or 604.800 seconds, got {0} instead")]
    MaxExpiry(u32),
    #[error("Got HTTP {0} with content '{1}'")]
    HttpFailWithBody(u16, String),
    #[error("Http request returned a non 2** code")]
    HttpFail,
    #[error("aws-creds: {0}")]
    Credentials(#[from] crate::creds::error::CredentialsError),
    #[error("aws-region: {0}")]
    Region(#[from] crate::region::error::RegionError),
    #[error("sha2 invalid length: {0}")]
    HmacInvalidLength(#[from] sha2::digest::InvalidLength),
    #[error("url parse: {0}")]
    UrlParse(#[from] url::ParseError),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[cfg(feature = "with-tokio")]
    #[error("http: {0}")]
    Http(#[from] http::Error),
    #[cfg(feature = "with-tokio")]
    #[error("reqwest: {0}")]
    Reqwest(#[from] reqwest::Error),
    #[cfg(feature = "with-tokio")]
    #[error("reqwest: {0}")]
    ReqwestHeaderToStr(#[from] reqwest::header::ToStrError),
    #[cfg(feature = "with-async-std")]
    #[error("header to string: {0}")]
    HeaderToStr(#[from] http::header::ToStrError),
    #[error("from utf8: {0}")]
    FromUtf8(#[from] std::string::FromUtf8Error),
    #[error("serde xml: {0}")]
    SerdeXml(#[from] quick_xml::de::DeError),
    #[error("invalid header value: {0}")]
    InvalidHeaderValue(#[from] http::header::InvalidHeaderValue),
    #[cfg(any(feature = "with-async-std", feature = "with-tokio"))]
    #[error("invalid header name: {0}")]
    InvalidHeaderName(#[from] http::header::InvalidHeaderName),
    #[cfg(feature = "with-async-std")]
    #[error("surf: {0}")]
    Surf(String),
    #[cfg(feature = "sync")]
    #[error("attohttpc: {0}")]
    Atto(#[from] attohttpc::Error),
    #[cfg(feature = "sync")]
    #[error("attohttpc: {0}")]
    AttoHeader(#[from] attohttpc::header::ToStrError),
    #[cfg(feature = "sync")]
    #[error("attohttpc: {0}")]
    AttoHeaderName(#[from] attohttpc::header::InvalidHeaderName),
    #[error("Could not get Write lock on Credentials")]
    WLCredentials,
    #[error("Could not get Read lock on Credentials")]
    RLCredentials,
    #[error("Time format error: {0}")]
    TimeFormatError(#[from] time::error::Format),
    #[error("fmt error: {0}")]
    FmtError(#[from] std::fmt::Error),
    #[error("serde error: {0}")]
    SerdeError(#[from] serde_json::Error),
    #[error("post policy error: {0}")]
    PostPolicyError(#[from] crate::post_policy::PostPolicyError),
    #[error("Could not get read lock on credentials")]
    CredentialsReadLock,
    #[error("Could not get write lock on credentials")]
    CredentialsWriteLock,
    #[error("xml serialization error: {0}")]
    XmlSeError(#[from] quick_xml::SeError),
}
