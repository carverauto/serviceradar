//! # Status
//!
//! This module exposes all the "standard" error codes defined in the File transfer protocol

use thiserror::Error;

#[derive(Debug, Copy, Clone, Error, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u32)]
/// Ftp status returned after command execution
pub enum Status {
    // 1xx: Positive Preliminary Reply
    #[error("restart marker reply")]
    RestartMarker = 110,
    #[error("service ready in (n) minutes")]
    ReadyMinute = 120,
    #[error("data connection already open, transfer starting")]
    AlreadyOpen = 125,
    #[error("file status okay, about to open data connection")]
    AboutToSend = 150,
    // 2xx: Positive Completion Reply
    #[error("command okay")]
    CommandOk = 200,
    #[error("command not implemented")]
    CommandNotImplemented = 202,
    #[error("system status, or system help reply")]
    System = 211,
    #[error("directory status")]
    Directory = 212,
    #[error("file status")]
    File = 213,
    #[error("help message")]
    Help = 214,
    #[error("NAME system type")]
    Name = 215,
    #[error("service ready for new user")]
    Ready = 220,
    #[error("service closing control connection")]
    Closing = 221,
    #[error("data connection open; no transfer in progress")]
    DataConnectionOpen = 225,
    #[error("closing data connection")]
    ClosingDataConnection = 226,
    #[error("entering passive mode")]
    PassiveMode = 227,
    #[error("entering long passive mode")]
    LongPassiveMode = 228,
    #[error("entering extended passive mode")]
    ExtendedPassiveMode = 229,
    #[error("user logged in, proceed. Logged out if appropriate.")]
    LoggedIn = 230,
    #[error("user logged out; service terminated")]
    LoggedOut = 231,
    #[error("logout command noted, will complete when transfer done")]
    LogoutAck = 232,
    #[error(
        "specifies that the server accepts the authentication mechanism specified by the client"
    )]
    AuthOk = 234,
    #[error("requested file action okay")]
    RequestedFileActionOk = 250,
    #[error("pathname created")]
    PathCreated = 257,
    // 3xx: Positive intermediate Reply
    #[error("user name okay, need password")]
    NeedPassword = 331,
    #[error("need account for login")]
    LoginNeedAccount = 332,
    #[error("requested file action pending further information")]
    RequestFilePending = 350,
    // 4xx: Transient Negative Completion Reply
    #[error("service not available, closing control connection")]
    NotAvailable = 421,
    #[error("can't open data connection")]
    CannotOpenDataConnection = 425,
    #[error("connection closed; transfer aborted")]
    TransferAborted = 426,
    #[error("invalid username or password")]
    InvalidCredentials = 430,
    #[error("requested host unavailable")]
    HostUnavailable = 434,
    #[error("requested file action not taken")]
    RequestFileActionIgnored = 450,
    #[error("requested action aborted")]
    ActionAborted = 451,
    #[error("requested action not taken")]
    RequestedActionNotTaken = 452,
    // 5xx: Permanent Negative Completion Reply
    #[error("syntax error, command unrecognized")]
    BadCommand = 500,
    #[error("syntax error in parameters or arguments")]
    BadArguments = 501,
    #[error("comamnd not implemented")]
    NotImplemented = 502,
    #[error("bad sequence of commands")]
    BadSequence = 503,
    #[error("command not implemented for that parameter")]
    NotImplementedParameter = 504,
    #[error("user not logged in")]
    NotLoggedIn = 530,
    #[error("need account for storing files")]
    StoringNeedAccount = 532,
    #[error("requested action not taken; file unavailable")]
    FileUnavailable = 550,
    #[error("requested action aborted; page type unknown")]
    PageTypeUnknown = 551,
    #[error("requested file action aborted; execeeded storage allocation")]
    ExceededStorage = 552,
    #[error("requested action not taken; file name not allowed")]
    BadFilename = 553,
    #[error("unknown error code")]
    Unknown = 0,
}

impl Status {
    /// Get status code
    pub fn code(&self) -> u32 {
        *self as u32
    }

    /// Get status description
    pub fn desc(&self) -> String {
        self.to_string()
    }
}

impl From<u32> for Status {
    fn from(code: u32) -> Self {
        match code {
            110 => Self::RestartMarker,
            120 => Self::ReadyMinute,
            125 => Self::AlreadyOpen,
            150 => Self::AboutToSend,
            200 => Self::CommandOk,
            202 => Self::CommandNotImplemented,
            211 => Self::System,
            212 => Self::Directory,
            213 => Self::File,
            214 => Self::Help,
            215 => Self::Name,
            220 => Self::Ready,
            221 => Self::Closing,
            225 => Self::DataConnectionOpen,
            226 => Self::ClosingDataConnection,
            227 => Self::PassiveMode,
            228 => Self::LongPassiveMode,
            229 => Self::ExtendedPassiveMode,
            230 => Self::LoggedIn,
            231 => Self::LoggedOut,
            232 => Self::LogoutAck,
            234 => Self::AuthOk,
            250 => Self::RequestedFileActionOk,
            257 => Self::PathCreated,
            331 => Self::NeedPassword,
            332 => Self::LoginNeedAccount,
            350 => Self::RequestFilePending,
            421 => Self::NotAvailable,
            425 => Self::CannotOpenDataConnection,
            426 => Self::TransferAborted,
            430 => Self::InvalidCredentials,
            434 => Self::HostUnavailable,
            450 => Self::RequestFileActionIgnored,
            451 => Self::ActionAborted,
            452 => Self::RequestedActionNotTaken,
            500 => Self::BadCommand,
            501 => Self::BadArguments,
            502 => Self::NotImplemented,
            503 => Self::BadSequence,
            504 => Self::NotImplementedParameter,
            530 => Self::NotLoggedIn,
            532 => Self::StoringNeedAccount,
            550 => Self::FileUnavailable,
            551 => Self::PageTypeUnknown,
            552 => Self::ExceededStorage,
            553 => Self::BadFilename,
            _ => Self::Unknown,
        }
    }
}

#[cfg(test)]
mod test {

    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn should_return_code_for_status() {
        assert_eq!(Status::BadFilename.code(), 553);
    }

    #[test]
    fn should_return_desc_for_status() {
        assert_eq!(
            Status::BadArguments.desc().as_str(),
            "syntax error in parameters or arguments"
        );
    }

    #[test]
    fn should_convert_u32_to_status() {
        assert_eq!(Status::from(110), Status::RestartMarker);
        assert_eq!(Status::from(120), Status::ReadyMinute);
        assert_eq!(Status::from(125), Status::AlreadyOpen);
        assert_eq!(Status::from(150), Status::AboutToSend);
        assert_eq!(Status::from(200), Status::CommandOk);
        assert_eq!(Status::from(202), Status::CommandNotImplemented);
        assert_eq!(Status::from(211), Status::System);
        assert_eq!(Status::from(212), Status::Directory);
        assert_eq!(Status::from(213), Status::File);
        assert_eq!(Status::from(214), Status::Help);
        assert_eq!(Status::from(215), Status::Name);
        assert_eq!(Status::from(220), Status::Ready);
        assert_eq!(Status::from(221), Status::Closing);
        assert_eq!(Status::from(225), Status::DataConnectionOpen);
        assert_eq!(Status::from(226), Status::ClosingDataConnection);
        assert_eq!(Status::from(227), Status::PassiveMode);
        assert_eq!(Status::from(228), Status::LongPassiveMode);
        assert_eq!(Status::from(229), Status::ExtendedPassiveMode);
        assert_eq!(Status::from(230), Status::LoggedIn);
        assert_eq!(Status::from(231), Status::LoggedOut);
        assert_eq!(Status::from(232), Status::LogoutAck);
        assert_eq!(Status::from(234), Status::AuthOk);
        assert_eq!(Status::from(250), Status::RequestedFileActionOk);
        assert_eq!(Status::from(257), Status::PathCreated);
        assert_eq!(Status::from(331), Status::NeedPassword);
        assert_eq!(Status::from(332), Status::LoginNeedAccount);
        assert_eq!(Status::from(350), Status::RequestFilePending);
        assert_eq!(Status::from(421), Status::NotAvailable);
        assert_eq!(Status::from(425), Status::CannotOpenDataConnection);
        assert_eq!(Status::from(426), Status::TransferAborted);
        assert_eq!(Status::from(430), Status::InvalidCredentials);
        assert_eq!(Status::from(434), Status::HostUnavailable);
        assert_eq!(Status::from(450), Status::RequestFileActionIgnored);
        assert_eq!(Status::from(451), Status::ActionAborted);
        assert_eq!(Status::from(452), Status::RequestedActionNotTaken);
        assert_eq!(Status::from(500), Status::BadCommand);
        assert_eq!(Status::from(501), Status::BadArguments);
        assert_eq!(Status::from(502), Status::NotImplemented);
        assert_eq!(Status::from(503), Status::BadSequence);
        assert_eq!(Status::from(504), Status::NotImplementedParameter);
        assert_eq!(Status::from(530), Status::NotLoggedIn);
        assert_eq!(Status::from(532), Status::StoringNeedAccount);
        assert_eq!(Status::from(550), Status::FileUnavailable);
        assert_eq!(Status::from(551), Status::PageTypeUnknown);
        assert_eq!(Status::from(552), Status::ExceededStorage);
        assert_eq!(Status::from(553), Status::BadFilename);
        assert_eq!(Status::from(999), Status::Unknown);
    }
}
