#[deprecated(since = "0.10.1", note = "Please use tcp_option::KIND_END instead")]
/// Deprecated please use [tcp_option::KIND_END] instead.
pub const TCP_OPTION_ID_END: u8 = 0;

#[deprecated(since = "0.10.1", note = "Please use tcp_option::KIND_NOOP instead")]
/// Deprecated please use [tcp_option::KIND_NOOP] instead.
pub const TCP_OPTION_ID_NOP: u8 = 1;

#[deprecated(
    since = "0.10.1",
    note = "Please use tcp_option::KIND_MAXIMUM_SEGMENT_SIZE instead"
)]
/// Deprecated please use [tcp_option::KIND_MAXIMUM_SEGMENT_SIZE] instead.
pub const TCP_OPTION_ID_MAXIMUM_SEGMENT_SIZE: u8 = 2;

#[deprecated(
    since = "0.10.1",
    note = "Please use tcp_option::KIND_WINDOW_SCALE instead"
)]
/// Deprecated please use [tcp_option::KIND_WINDOW_SCALE] instead.
pub const TCP_OPTION_ID_WINDOW_SCALE: u8 = 3;

#[deprecated(
    since = "0.10.1",
    note = "Please use tcp_option::KIND_SELECTIVE_ACK_PERMITTED instead"
)]
/// Deprecated please use [tcp_option::KIND_SELECTIVE_ACK_PERMITTED] instead.
pub const TCP_OPTION_ID_SELECTIVE_ACK_PERMITTED: u8 = 4;

#[deprecated(
    since = "0.10.1",
    note = "Please use tcp_option::KIND_SELECTIVE_ACK instead"
)]
/// Deprecated please use [tcp_option::KIND_SELECTIVE_ACK] instead.
pub const TCP_OPTION_ID_SELECTIVE_ACK: u8 = 5;

#[deprecated(
    since = "0.10.1",
    note = "Please use tcp_option::KIND_TIMESTAMP instead"
)]
/// Deprecated please use [tcp_option::KIND_TIMESTAMP] instead.
pub const TCP_OPTION_ID_TIMESTAMP: u8 = 8;

/// Module containing the constants for tcp options (id number & sizes).
pub mod tcp_option {
    /// `u8` identifying the "end of options list" in the tcp option.
    pub const KIND_END: u8 = 0;
    /// `u8` identifying a "no operation" tcp option.
    pub const KIND_NOOP: u8 = 1;
    /// `u8` identifying a "maximum segment size" tcp option.
    pub const KIND_MAXIMUM_SEGMENT_SIZE: u8 = 2;
    /// `u8` identifying a "window scaling" tcp option.
    pub const KIND_WINDOW_SCALE: u8 = 3;
    /// `u8` identifying a "selective acknowledgement permitted" tcp option.
    pub const KIND_SELECTIVE_ACK_PERMITTED: u8 = 4;
    /// `u8` identifying a "selective acknowledgement" tcp option.
    pub const KIND_SELECTIVE_ACK: u8 = 5;
    /// `u8` identifying a "timestamp and echo of previous timestamp" tcp option.
    pub const KIND_TIMESTAMP: u8 = 8;
    /// Length in octets/bytes of the "end" tcp option (includes kind value).
    pub const LEN_END: u8 = 1;
    /// Length in octets/bytes of the "no operation" tcp option (includes kind value).
    pub const LEN_NOOP: u8 = 1;
    /// Length in octets/bytes of the "maximum segment size" tcp option (includes kind value).
    pub const LEN_MAXIMUM_SEGMENT_SIZE: u8 = 4;
    /// Length in octets/bytes of the "window scaling" tcp option (includes kind value).
    pub const LEN_WINDOW_SCALE: u8 = 3;
    /// Length in octets/bytes of the "selective acknowledgement permitted" tcp option (includes kind value).
    pub const LEN_SELECTIVE_ACK_PERMITTED: u8 = 2;
    /// Length in octets/bytes of the "timestamp and echo of previous timestamp" tcp option (includes kind value).
    pub const LEN_TIMESTAMP: u8 = 10;
}
