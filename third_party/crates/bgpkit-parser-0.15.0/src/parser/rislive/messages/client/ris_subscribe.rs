use crate::rislive::messages::RisLiveClientMessage;
use ipnet::IpNet;
use serde::Serialize;
use std::net::IpAddr;

#[derive(Debug, Serialize)]
#[allow(clippy::upper_case_acronyms)]
pub enum RisSubscribeType {
    UPDATE,
    OPEN,
    NOTIFICATION,
    KEEPALIVE,
    RIS_PEER_STATE,
}

#[derive(Debug, Serialize)]
pub struct RisSubscribeSocketOptions {
    /// Include a Base64-encoded version of the original binary BGP message as `raw` for all subscriptions
    ///
    /// *Default: false*
    #[serde(rename = "includeRaw")]
    pub include_raw: Option<bool>,

    /// Send a `ris_subscribe_ok` message for all succesful subscriptions
    ///
    /// *Default: false*
    pub acknowledge: Option<bool>,
}

#[derive(Default, Debug, Serialize)]
pub struct RisSubscribe {
    /// Only include messages collected by a particular RRC
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,

    /// Only include messages of a given BGP or RIS type
    #[serde(rename = "type")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data_type: Option<RisSubscribeType>,

    /// Only include messages containing a given key
    ///
    /// Examples:
    /// * "announcements"
    /// * "withdrawals"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub require: Option<String>,

    /// Only include messages sent by the given BGP peer
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peer: Option<IpAddr>,

    /// ASN or pattern to match against the AS PATH attribute
    ///
    /// Any of:
    /// * ASN (integer)
    /// * AS path pattern (string)
    ///
    /// Comma-separated pattern describing all or part of the AS path.
    /// Can optionally begin with ^ to match the first item of the path (the last traversed ASN),
    /// and/or end with $ to match the last item of the path
    /// (the originating ASN).
    ///
    /// The entire pattern can be prefixed with ! to invert the match.
    /// AS_SETs should be written as JSON arrays of integers in ascending order and with no spaces.
    /// Note: this is not a regular expression.
    ///
    /// Examples:
    /// * "789$"
    /// * "^123,456,789,[789,10111]$"
    /// * "!6666$"
    /// * "!^3333"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,

    /// Filter UPDATE messages by prefixes in announcements or withdrawals
    ///
    /// Any of:
    /// * IPv4 or IPv6 CIDR prefix (string)
    /// * Array of CIDR prefixes (array)
    ///
    /// For the purposes of subsequent `ris_unsubscribe` messages,
    /// each prefix results in a separate subscription that can be stopped independently
    ///
    /// Array items:
    /// * IPv4 or IPv6 CIDR prefix (string)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prefix: Option<IpNet>,

    /// Match prefixes that are more specific (part of) `prefix`
    ///
    /// *Default: true*
    #[serde(rename = "moreSpecific")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub more_specific: Option<bool>,

    /// Match prefixes that are less specific (contain) `prefix`
    ///
    /// *Default: false*
    #[serde(rename = "lessSpecific")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub less_specific: Option<bool>,

    /// Options that apply to all subscriptions over the current WebSocket.
    /// If a new subscription contains `socketOptions` it will override those from previous subscriptions
    #[serde(rename = "socketOptions")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub socket_options: Option<RisSubscribeSocketOptions>,
}

impl RisSubscribe {
    pub fn new() -> Self {
        Default::default()
    }

    pub fn host(mut self, host: &str) -> Self {
        self.host = Some(host.to_string());
        self
    }

    pub fn data_type(mut self, data_type: RisSubscribeType) -> Self {
        self.data_type = Some(data_type);
        self
    }

    pub fn require(mut self, require: &str) -> Self {
        self.require = Some(require.to_string());
        self
    }

    pub fn peer(mut self, peer: IpAddr) -> Self {
        self.peer = Some(peer);
        self
    }

    pub fn path(mut self, path: &str) -> Self {
        self.path = Some(path.to_string());
        self
    }

    pub fn prefix(mut self, prefix: IpNet) -> Self {
        self.prefix = Some(prefix);
        self
    }

    pub fn more_specific(mut self, more_specific: bool) -> Self {
        self.more_specific = Some(more_specific);
        self
    }

    pub fn less_specific(mut self, less_specific: bool) -> Self {
        self.less_specific = Some(less_specific);
        self
    }

    pub fn include_raw(mut self, include_raw: bool) -> Self {
        match self.socket_options.as_mut() {
            None => {
                self.socket_options = Some(RisSubscribeSocketOptions {
                    include_raw: Some(include_raw),
                    acknowledge: None,
                });
            }
            Some(o) => {
                o.include_raw = Some(include_raw);
            }
        }
        self
    }

    pub fn acknowledge(mut self, acknowledge: bool) -> Self {
        match self.socket_options.as_mut() {
            None => {
                self.socket_options = Some(RisSubscribeSocketOptions {
                    include_raw: None,
                    acknowledge: Some(acknowledge),
                });
            }
            Some(o) => {
                o.acknowledge = Some(acknowledge);
            }
        }
        self
    }
}

impl RisLiveClientMessage for RisSubscribe {
    fn msg_type(&self) -> &'static str {
        "ris_subscribe"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new() {
        let ris_subscribe = RisSubscribe::new()
            .host("rrc00")
            .data_type(RisSubscribeType::UPDATE);
        assert_eq!(ris_subscribe.host, Some("rrc00".to_string()));

        println!("{}", ris_subscribe.to_json_string());
    }
}
