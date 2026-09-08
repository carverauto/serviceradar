use super::*;

#[derive(Debug, Clone, Copy, PartialEq)]
pub(in crate::query::flows) enum FlowGroupField {
    SrcEndpointIp,
    DstEndpointIp,
    ConversationAIp,
    ConversationBIp,
    SrcEndpointPort,
    DstEndpointPort,
    ProtocolNum,
    ProtocolName,
    ProtocolGroup,
    FlowSource,
    SamplerAddress,
    ExporterName,
    InputSnmp,
    OutputSnmp,
    InIfName,
    OutIfName,
    InIfSpeedBps,
    OutIfSpeedBps,
    Direction,
    App,
    SrcCountryIso2,
    DstCountryIso2,
    TcpFlagsLabel,
    DurationBucket,
    AttributionStatus,
}

impl FlowGroupField {
    pub(in crate::query::flows) fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "src_endpoint_ip" | "src_ip" => Some(Self::SrcEndpointIp),
            "dst_endpoint_ip" | "dst_ip" => Some(Self::DstEndpointIp),
            "conversation_a_ip" | "conversation_min_ip" => Some(Self::ConversationAIp),
            "conversation_b_ip" | "conversation_max_ip" => Some(Self::ConversationBIp),
            "src_endpoint_port" | "src_port" => Some(Self::SrcEndpointPort),
            "dst_endpoint_port" | "dst_port" => Some(Self::DstEndpointPort),
            "protocol_num" | "proto" => Some(Self::ProtocolNum),
            "protocol_name" => Some(Self::ProtocolName),
            "protocol_group" | "proto_group" => Some(Self::ProtocolGroup),
            "flow_source" | "collector" => Some(Self::FlowSource),
            "sampler_address" => Some(Self::SamplerAddress),
            "exporter_name" => Some(Self::ExporterName),
            "input_snmp" | "in_if_index" => Some(Self::InputSnmp),
            "output_snmp" | "out_if_index" => Some(Self::OutputSnmp),
            "in_if_name" => Some(Self::InIfName),
            "out_if_name" => Some(Self::OutIfName),
            "in_if_speed_bps" => Some(Self::InIfSpeedBps),
            "out_if_speed_bps" => Some(Self::OutIfSpeedBps),
            "direction" => Some(Self::Direction),
            "app" => Some(Self::App),
            "src_country_iso2" | "src_country" => Some(Self::SrcCountryIso2),
            "dst_country_iso2" | "dst_country" => Some(Self::DstCountryIso2),
            "tcp_flags_label" | "tcp_flag" => Some(Self::TcpFlagsLabel),
            "duration_bucket" | "duration" => Some(Self::DurationBucket),
            "attribution_status" | "status" => Some(Self::AttributionStatus),
            _ => None,
        }
    }

    pub(in crate::query::flows) fn response_key(&self) -> &'static str {
        match self {
            Self::SrcEndpointIp => "src_endpoint_ip",
            Self::DstEndpointIp => "dst_endpoint_ip",
            Self::ConversationAIp => "conversation_a_ip",
            Self::ConversationBIp => "conversation_b_ip",
            Self::SrcEndpointPort => "src_endpoint_port",
            Self::DstEndpointPort => "dst_endpoint_port",
            Self::ProtocolNum => "protocol_num",
            Self::ProtocolName => "protocol_name",
            Self::ProtocolGroup => "protocol_group",
            Self::FlowSource => "flow_source",
            Self::SamplerAddress => "sampler_address",
            Self::ExporterName => "exporter_name",
            Self::InputSnmp => "input_snmp",
            Self::OutputSnmp => "output_snmp",
            Self::InIfName => "in_if_name",
            Self::OutIfName => "out_if_name",
            Self::InIfSpeedBps => "in_if_speed_bps",
            Self::OutIfSpeedBps => "out_if_speed_bps",
            Self::Direction => "direction",
            Self::App => "app",
            Self::SrcCountryIso2 => "src_country_iso2",
            Self::DstCountryIso2 => "dst_country_iso2",
            Self::TcpFlagsLabel => "tcp_flags_label",
            Self::DurationBucket => "duration_bucket",
            Self::AttributionStatus => "attribution_status",
        }
    }

    pub(in crate::query::flows) fn group_expr(&self) -> &'static str {
        match self {
            Self::SrcEndpointIp => "src_endpoint_ip",
            Self::DstEndpointIp => "dst_endpoint_ip",
            Self::ConversationAIp => FLOW_CONVERSATION_A_IP_EXPR,
            Self::ConversationBIp => FLOW_CONVERSATION_B_IP_EXPR,
            Self::SrcEndpointPort => "src_endpoint_port",
            Self::DstEndpointPort => "dst_endpoint_port",
            Self::ProtocolNum => "protocol_num",
            Self::ProtocolName => "protocol_name",
            Self::ProtocolGroup => FLOW_PROTOCOL_GROUP_EXPR,
            Self::FlowSource => FLOW_SOURCE_EXPR,
            Self::SamplerAddress => "sampler_address",
            Self::ExporterName => FLOW_EXPORTER_NAME_GROUP_EXPR,
            Self::InputSnmp => FLOW_INPUT_SNMP_GROUP_EXPR,
            Self::OutputSnmp => FLOW_OUTPUT_SNMP_GROUP_EXPR,
            Self::InIfName => FLOW_IN_IF_NAME_GROUP_EXPR,
            Self::OutIfName => FLOW_OUT_IF_NAME_GROUP_EXPR,
            Self::InIfSpeedBps => FLOW_IN_IF_SPEED_BPS_GROUP_EXPR,
            Self::OutIfSpeedBps => FLOW_OUT_IF_SPEED_BPS_GROUP_EXPR,
            Self::Direction => FLOW_DIRECTION_EXPR,
            Self::App => FLOW_APP_EXPR,
            Self::SrcCountryIso2 => "COALESCE(src_geo.country_iso2, 'Unknown')",
            Self::DstCountryIso2 => "COALESCE(dst_geo.country_iso2, 'Unknown')",
            Self::TcpFlagsLabel => FLOW_TCP_FLAGS_LABEL_EXPR,
            Self::DurationBucket => FLOW_DURATION_BUCKET_EXPR,
            Self::AttributionStatus => ATTRIBUTION_STATUS_EXPR_ALIASED,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(in crate::query::flows) enum FlowGroupSpec {
    Field(FlowGroupField),
    SrcCidr { prefix: u8 },
    DstCidr { prefix: u8 },
}

impl FlowGroupSpec {
    pub(in crate::query::flows) fn parse(token: &str) -> Result<Self> {
        if let Some((kind, rest)) = token.split_once(':') {
            let kind = kind.to_lowercase();
            let prefix: u8 = rest.parse().map_err(|_| {
                ServiceError::InvalidRequest(format!(
                    "invalid CIDR prefix length in group-by: '{token}'"
                ))
            })?;
            if prefix > 32 {
                return Err(ServiceError::InvalidRequest(format!(
                    "CIDR prefix length must be <= 32 (got {prefix})"
                )));
            }
            match kind.as_str() {
                "src_cidr" => return Ok(Self::SrcCidr { prefix }),
                "dst_cidr" => return Ok(Self::DstCidr { prefix }),
                _ => {}
            }
        }

        if let Some(field) = FlowGroupField::from_str(token) {
            return Ok(Self::Field(field));
        }

        Err(ServiceError::InvalidRequest(format!(
            "unsupported group-by field for flows stats: '{token}'"
        )))
    }

    pub(in crate::query::flows) fn response_key(&self) -> &'static str {
        match self {
            Self::Field(field) => field.response_key(),
            Self::SrcCidr { .. } => "src_cidr",
            Self::DstCidr { .. } => "dst_cidr",
        }
    }

    pub(in crate::query::flows) fn group_expr(&self) -> String {
        match self {
            Self::Field(field) => field.group_expr().to_string(),
            Self::SrcCidr { prefix } => format!(
                "COALESCE(set_masklen(try_inet(NULLIF(src_endpoint_ip, '')), {prefix})::text, 'Unknown')"
            ),
            Self::DstCidr { prefix } => format!(
                "COALESCE(set_masklen(try_inet(NULLIF(dst_endpoint_ip, '')), {prefix})::text, 'Unknown')"
            ),
        }
    }
}
