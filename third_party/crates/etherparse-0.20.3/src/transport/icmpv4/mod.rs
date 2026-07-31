mod dest_unreachable_header;
pub use dest_unreachable_header::*;

mod parameter_problem_header;
pub use parameter_problem_header::*;

mod redirect_code;
pub use redirect_code::*;

mod redirect_header;
pub use redirect_header::*;

mod time_exceeded_code;
pub use time_exceeded_code::*;

mod timestamp_message;
pub use timestamp_message::*;

/// ICMPv4 type value indicating a "Echo Reply" message (defined in [RFC 792](https://tools.ietf.org/html/rfc792)).
pub const TYPE_ECHO_REPLY: u8 = 0;

/// ICMPv4 type value indicating a "Destination Unreachable" message (defined in [RFC 792](https://tools.ietf.org/html/rfc792)).
pub const TYPE_DEST_UNREACH: u8 = 3;

/// ICMPv4 type value indicating a "Source Quench (Deprecated)" message (defined in in [RFC 792](https://tools.ietf.org/html/rfc792), deprecated in [RFC 6633](https://tools.ietf.org/html/rfc6633)).
pub const TYPE_SOURCE_QUENCH: u8 = 4;

/// ICMPv4 type value indicating a "Redirect" message (defined in [RFC 792](https://tools.ietf.org/html/rfc792)).
pub const TYPE_REDIRECT: u8 = 5;

/// ICMPv4 type value indicating a "Alternate Host Address (Deprecated)" message (deprecated in [RFC 6918](https://tools.ietf.org/html/rfc6918)).
pub const TYPE_ALTERNATE_HOST_ADDRESS: u8 = 6;

/// ICMPv4 type value indicating a "Echo Request" message (defined in [RFC 792](https://tools.ietf.org/html/rfc792)).
pub const TYPE_ECHO_REQUEST: u8 = 8;

/// ICMPv4 type value indicating a "Router Advertisement" message (defined in [RFC 1256](https://tools.ietf.org/html/rfc1256)).
pub const TYPE_ROUTER_ADVERTISEMENT: u8 = 9;

/// ICMPv4 type value indicating a "Router Solicitation" message (defined in [RFC 1256](https://tools.ietf.org/html/rfc1256)).
pub const TYPE_ROUTER_SOLICITATION: u8 = 10;

/// ICMPv4 type value indicating a "Time Exceeded" message (defined in [RFC 792](https://tools.ietf.org/html/rfc792)).
pub const TYPE_TIME_EXCEEDED: u8 = 11;

/// ICMPv4 type value indicating a "Parameter Problem" message (defined in [RFC 792](https://tools.ietf.org/html/rfc792)).
pub const TYPE_PARAMETER_PROBLEM: u8 = 12;

/// ICMPv4 type value indicating a "Timestamp" message (defined in [RFC 792](https://tools.ietf.org/html/rfc792)).
pub const TYPE_TIMESTAMP: u8 = 13;

/// ICMPv4 type value indicating a "Timestamp Reply" message (defined in [RFC 792](https://tools.ietf.org/html/rfc792)).
pub const TYPE_TIMESTAMP_REPLY: u8 = 14;

/// ICMPv4 type value indicating a "Information Request (Deprecated)" message (defined in in [RFC 792](https://tools.ietf.org/html/rfc792), deprecated in [RFC 6918](https://tools.ietf.org/html/rfc6918)).
pub const TYPE_INFO_REQUEST: u8 = 15;

/// ICMPv4 type value indicating a "Information Reply (Deprecated)" message (defined in in [RFC 792](https://tools.ietf.org/html/rfc792), deprecated in [RFC 6918](https://tools.ietf.org/html/rfc6918)).
pub const TYPE_INFO_REPLY: u8 = 16;

/// ICMPv4 type value indicating a "Address Mask Request (Deprecated)" message (defined in in [RFC 950](https://tools.ietf.org/html/rfc950), deprecated in [RFC 6918](https://tools.ietf.org/html/rfc6918)).
pub const TYPE_ADDRESS: u8 = 17;

/// ICMPv4 type value indicating a "Address Mask Reply (Deprecated)" message (defined in in [RFC 950](https://tools.ietf.org/html/rfc950), deprecated in [RFC 6918](https://tools.ietf.org/html/rfc6918)).
pub const TYPE_ADDRESSREPLY: u8 = 18;

/// ICMP destination unreachable code for "Net Unreachable" (defined in [RFC 792](https://tools.ietf.org/html/rfc792))
pub const CODE_DST_UNREACH_NET: u8 = 0;

/// ICMP destination unreachable code for "Host Unreachable" (defined in [RFC 792](https://tools.ietf.org/html/rfc792))
pub const CODE_DST_UNREACH_HOST: u8 = 1;

/// ICMP destination unreachable code for "Protocol Unreachable" (defined in [RFC 792](https://tools.ietf.org/html/rfc792))
pub const CODE_DST_UNREACH_PROTOCOL: u8 = 2;

/// ICMP destination unreachable code for "Port Unreachable" (defined in [RFC 792](https://tools.ietf.org/html/rfc792))
pub const CODE_DST_UNREACH_PORT: u8 = 3;

/// ICMP destination unreachable code for "Fragmentation Needed and Don't Fragment was Set" (defined in [RFC 792](https://tools.ietf.org/html/rfc792))
pub const CODE_DST_UNREACH_NEED_FRAG: u8 = 4;

/// ICMP destination unreachable code for "Source Route Failed" (defined in [RFC 792](https://tools.ietf.org/html/rfc792))
pub const CODE_DST_UNREACH_SOURCE_ROUTE_FAILED: u8 = 5;

/// ICMP destination unreachable code for "Destination Network Unknown" (defined in [RFC 1122](https://tools.ietf.org/html/rfc1122))
pub const CODE_DST_UNREACH_NET_UNKNOWN: u8 = 6;

/// ICMP destination unreachable code for "Destination Host Unknown" (defined in [RFC 1122](https://tools.ietf.org/html/rfc1122))
pub const CODE_DST_UNREACH_HOST_UNKNOWN: u8 = 7;

/// ICMP destination unreachable code for "Source Host Isolated" (defined in [RFC 1122](https://tools.ietf.org/html/rfc1122))
pub const CODE_DST_UNREACH_ISOLATED: u8 = 8;

/// ICMP destination unreachable code for "Communication with Destination Network is Administratively Prohibited" (defined in [RFC 1122](https://tools.ietf.org/html/rfc1122))
pub const CODE_DST_UNREACH_NET_PROHIB: u8 = 9;

/// ICMP destination unreachable code for "Communication with Destination Host is Administratively Prohibited" (defined in [RFC 1122](https://tools.ietf.org/html/rfc1122))
pub const CODE_DST_UNREACH_HOST_PROHIB: u8 = 10;

/// ICMP destination unreachable code for "Destination Network Unreachable for Type of Service" (defined in [RFC 1122](https://tools.ietf.org/html/rfc1122))
pub const CODE_DST_UNREACH_TOS_NET: u8 = 11;

/// ICMP destination unreachable code for "Destination Host Unreachable for Type of Service" (defined in [RFC 1122](https://tools.ietf.org/html/rfc1122))
pub const CODE_DST_UNREACH_TOS_HOST: u8 = 12;

/// ICMP destination unreachable code for "Communication Administratively Prohibited" (defined in [RFC 1812](https://tools.ietf.org/html/rfc1812))
pub const CODE_DST_UNREACH_FILTER_PROHIB: u8 = 13;

/// ICMP destination unreachable code for "Host Precedence Violation" (defined in [RFC 1812](https://tools.ietf.org/html/rfc1812))
pub const CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION: u8 = 14;

/// ICMP destination unreachable code for "Precedence cutoff in effect" (defined in [RFC 1812](https://tools.ietf.org/html/rfc1812))
pub const CODE_DST_UNREACH_PRECEDENCE_CUTOFF: u8 = 15;

/// ICMPv4 "Redirect" code value for "Redirect Datagram for the Network (or subnet)".
pub const CODE_REDIRECT_FOR_NETWORK: u8 = 0;

/// ICMPv4 "Redirect" code value for "Redirect Datagram for the Host".
pub const CODE_REDIRECT_FOR_HOST: u8 = 1;

/// ICMPv4 "Redirect" code value for "Redirect Datagram for the Type of Service and Network".
pub const CODE_REDIRECT_TYPE_OF_SERVICE_AND_NETWORK: u8 = 2;

/// ICMPv4 "Redirect" code value for "Redirect Datagram for the Type of Service and Host".
pub const CODE_REDIRECT_TYPE_OF_SERVICE_AND_HOST: u8 = 3;

/// ICMPv4 "Time Exceeded" code value for "Time to Live exceeded in Transit".
pub const CODE_TIME_EXCEEDED_TTL_EXCEEDED_IN_TRANSIT: u8 = 0;

/// ICMPv4 "Time Exceeded" code value for "Fragment Reassembly Time Exceeded".
pub const CODE_TIME_EXCEEDED_FRAG_REASSEMBLY_TIME_EXCEEDED: u8 = 1;

/// ICMPv4 "Parameter Problem" code value for "Pointer indicates the error".
pub const CODE_PARAMETER_PROBLEM_POINTER_INDICATES_ERROR: u8 = 0;

/// ICMPv4 "Parameter Problem" code value for "Missing a Required Option".
pub const CODE_PARAMETER_PROBLEM_MISSING_REQUIRED_OPTION: u8 = 1;

/// ICMPv4 "Parameter Problem" code value for "Bad Length".
pub const CODE_PARAMETER_PROBLEM_BAD_LENGTH: u8 = 2;

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn constants() {
        // icmp type numbers according to
        // https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml#icmp-parameters-types
        assert_eq!(TYPE_ECHO_REPLY, 0);
        assert_eq!(TYPE_DEST_UNREACH, 3);
        assert_eq!(TYPE_SOURCE_QUENCH, 4);
        assert_eq!(TYPE_REDIRECT, 5);
        assert_eq!(TYPE_ALTERNATE_HOST_ADDRESS, 6);
        assert_eq!(TYPE_ECHO_REQUEST, 8);
        assert_eq!(TYPE_ROUTER_ADVERTISEMENT, 9);
        assert_eq!(TYPE_ROUTER_SOLICITATION, 10);
        assert_eq!(TYPE_TIME_EXCEEDED, 11);
        assert_eq!(TYPE_PARAMETER_PROBLEM, 12);
        assert_eq!(TYPE_TIMESTAMP, 13);
        assert_eq!(TYPE_TIMESTAMP_REPLY, 14);
        assert_eq!(TYPE_INFO_REQUEST, 15);
        assert_eq!(TYPE_INFO_REPLY, 16);
        assert_eq!(TYPE_ADDRESS, 17);
        assert_eq!(TYPE_ADDRESSREPLY, 18);

        // destination unreachable code numbers according to
        // https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml#icmp-parameters-codes-3
        assert_eq!(0, CODE_DST_UNREACH_NET);
        assert_eq!(1, CODE_DST_UNREACH_HOST);
        assert_eq!(2, CODE_DST_UNREACH_PROTOCOL);
        assert_eq!(3, CODE_DST_UNREACH_PORT);
        assert_eq!(4, CODE_DST_UNREACH_NEED_FRAG);
        assert_eq!(5, CODE_DST_UNREACH_SOURCE_ROUTE_FAILED);
        assert_eq!(6, CODE_DST_UNREACH_NET_UNKNOWN);
        assert_eq!(7, CODE_DST_UNREACH_HOST_UNKNOWN);
        assert_eq!(8, CODE_DST_UNREACH_ISOLATED);
        assert_eq!(9, CODE_DST_UNREACH_NET_PROHIB);
        assert_eq!(10, CODE_DST_UNREACH_HOST_PROHIB);
        assert_eq!(11, CODE_DST_UNREACH_TOS_NET);
        assert_eq!(12, CODE_DST_UNREACH_TOS_HOST);
        assert_eq!(13, CODE_DST_UNREACH_FILTER_PROHIB);
        assert_eq!(14, CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION);
        assert_eq!(15, CODE_DST_UNREACH_PRECEDENCE_CUTOFF);

        // redirect code numbers according to
        // https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml#icmp-parameters-codes-5
        assert_eq!(0, CODE_REDIRECT_FOR_NETWORK);
        assert_eq!(1, CODE_REDIRECT_FOR_HOST);
        assert_eq!(2, CODE_REDIRECT_TYPE_OF_SERVICE_AND_NETWORK);
        assert_eq!(3, CODE_REDIRECT_TYPE_OF_SERVICE_AND_HOST);

        // time exceeded code numbers according to
        // https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml#icmp-parameters-codes-11
        assert_eq!(0, CODE_TIME_EXCEEDED_TTL_EXCEEDED_IN_TRANSIT);
        assert_eq!(1, CODE_TIME_EXCEEDED_FRAG_REASSEMBLY_TIME_EXCEEDED);

        // parameter problem code numbers according to
        // https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml#icmp-parameters-codes-12
        assert_eq!(0, CODE_PARAMETER_PROBLEM_POINTER_INDICATES_ERROR);
        assert_eq!(1, CODE_PARAMETER_PROBLEM_MISSING_REQUIRED_OPTION);
        assert_eq!(2, CODE_PARAMETER_PROBLEM_BAD_LENGTH);
    }
}
