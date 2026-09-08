#[derive(Debug, Clone, Copy, PartialEq)]
pub(in crate::query::flows) enum FlowAggFunc {
    Count,
    CountDistinct,
    Sum,
    Avg,
    Min,
    Max,
}

impl FlowAggFunc {
    pub(in crate::query::flows) fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "count" => Some(Self::Count),
            "count_distinct" => Some(Self::CountDistinct),
            "sum" => Some(Self::Sum),
            "avg" => Some(Self::Avg),
            "min" => Some(Self::Min),
            "max" => Some(Self::Max),
            _ => None,
        }
    }

    pub(in crate::query::flows) fn sql(&self) -> &'static str {
        match self {
            Self::Count => "COUNT",
            Self::CountDistinct => "COUNT",
            Self::Sum => "SUM",
            Self::Avg => "AVG",
            Self::Min => "MIN",
            Self::Max => "MAX",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(in crate::query::flows) enum FlowAggField {
    Star,
    SrcEndpointIp,
    DstEndpointIp,
    BytesTotal,
    PacketsTotal,
    BytesIn,
    BytesOut,
    PacketsIn,
    PacketsOut,
    SrcEndpointPort,
    DstEndpointPort,
    /// The flow event timestamp (`time`). Only valid for min/max aggregations
    /// used to derive the data's covered time span (§38.1); never a sampled
    /// volume field, so it is excluded from `is_sampled_volume`.
    Time,
}

impl FlowAggField {
    pub(in crate::query::flows) fn from_str(s: &str) -> Option<Self> {
        match s {
            "*" => Some(Self::Star),
            "src_endpoint_ip" | "src_ip" => Some(Self::SrcEndpointIp),
            "dst_endpoint_ip" | "dst_ip" => Some(Self::DstEndpointIp),
            "bytes_total" => Some(Self::BytesTotal),
            "packets_total" => Some(Self::PacketsTotal),
            "bytes_in" => Some(Self::BytesIn),
            "bytes_out" => Some(Self::BytesOut),
            "packets_in" => Some(Self::PacketsIn),
            "packets_out" => Some(Self::PacketsOut),
            "src_endpoint_port" | "src_port" => Some(Self::SrcEndpointPort),
            "dst_endpoint_port" | "dst_port" => Some(Self::DstEndpointPort),
            "time" => Some(Self::Time),
            _ => None,
        }
    }

    pub(in crate::query::flows) fn sql(&self) -> &'static str {
        match self {
            Self::Star => "*",
            Self::SrcEndpointIp => "src_endpoint_ip",
            Self::DstEndpointIp => "dst_endpoint_ip",
            Self::BytesTotal => "bytes_total",
            Self::PacketsTotal => "packets_total",
            Self::BytesIn => "bytes_in",
            Self::BytesOut => "bytes_out",
            Self::PacketsIn => "packets_in",
            Self::PacketsOut => "packets_out",
            Self::SrcEndpointPort => "src_endpoint_port",
            Self::DstEndpointPort => "dst_endpoint_port",
            Self::Time => "time",
        }
    }

    pub(in crate::query::flows) fn is_sampled_volume(&self) -> bool {
        matches!(
            self,
            Self::BytesTotal
                | Self::PacketsTotal
                | Self::BytesIn
                | Self::BytesOut
                | Self::PacketsIn
                | Self::PacketsOut
        )
    }

    pub(in crate::query::flows) fn is_nullable_directional_volume(&self) -> bool {
        matches!(
            self,
            Self::BytesIn | Self::BytesOut | Self::PacketsIn | Self::PacketsOut
        )
    }

    pub(in crate::query::flows) fn sampled_volume_sql(&self, table_alias: &str) -> Option<String> {
        self.is_sampled_volume().then(|| {
            let column = self.sql();
            let value_sql = if self.is_nullable_directional_volume() {
                format!("COALESCE({table_alias}.{column}, 0)")
            } else {
                format!("{table_alias}.{column}")
            };

            format!(
                "({value_sql}::double precision * GREATEST(COALESCE({table_alias}.sampling_rate, 1), 1)::double precision)"
            )
        })
    }
}
