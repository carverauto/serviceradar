use crate::parser::{Filter, FilterOp, FilterValue};

pub(super) const MAX_FILTER_LIST_VALUES: usize = 200;

pub(super) fn build_filter(key: &str, value: FilterValue) -> Filter {
    let mut field = key.trim();
    let mut negated = false;
    if let Some(stripped) = field.strip_prefix('!') {
        field = stripped;
        negated = true;
    }

    let (op, final_value) = match value {
        FilterValue::Scalar(v) => {
            if let Some(stripped) = v.strip_prefix(">=") {
                (FilterOp::Gte, FilterValue::Scalar(stripped.to_string()))
            } else if let Some(stripped) = v.strip_prefix('>') {
                (FilterOp::Gt, FilterValue::Scalar(stripped.to_string()))
            } else if let Some(stripped) = v.strip_prefix("<=") {
                (FilterOp::Lte, FilterValue::Scalar(stripped.to_string()))
            } else if let Some(stripped) = v.strip_prefix('<') {
                (FilterOp::Lt, FilterValue::Scalar(stripped.to_string()))
            } else if v.contains('%') && supports_implicit_like(field) {
                if negated {
                    (FilterOp::NotLike, FilterValue::Scalar(v))
                } else {
                    (FilterOp::Like, FilterValue::Scalar(v))
                }
            } else if negated {
                (FilterOp::NotEq, FilterValue::Scalar(v))
            } else {
                (FilterOp::Eq, FilterValue::Scalar(v))
            }
        }
        FilterValue::List(_) => {
            if negated {
                (FilterOp::NotIn, value)
            } else {
                (FilterOp::In, value)
            }
        }
    };

    Filter {
        field: field.to_lowercase(),
        op,
        value: final_value,
    }
}

fn supports_implicit_like(field: &str) -> bool {
    let field = field.to_ascii_lowercase();
    if field.starts_with("metadata.") {
        return true;
    }

    matches!(
        field.as_str(),
        "activity"
            | "agent_id"
            | "aos_version"
            | "app"
            | "application"
            | "attributes"
            | "category"
            | "classification"
            | "cluster"
            | "collector"
            | "component"
            | "cpe"
            | "cpes"
            | "description"
            | "destination"
            | "device"
            | "device_id"
            | "device_ip"
            | "direction"
            | "dst_endpoint_ip"
            | "dst_ip"
            | "dst_port"
            | "entity"
            | "event"
            | "event_name"
            | "gateway_id"
            | "host"
            | "hostname"
            | "id"
            | "ingest_agent_id"
            | "interface"
            | "ip"
            | "label"
            | "mac"
            | "manager"
            | "message"
            | "name"
            | "namespace"
            | "package"
            | "parent_span_id"
            | "protocol"
            | "protocol_group"
            | "provider"
            | "purl"
            | "resource"
            | "root_span_id"
            | "service"
            | "service_name"
            | "service_namespace"
            | "service_type"
            | "severity"
            | "source"
            | "source_type"
            | "span_id"
            | "src_endpoint_ip"
            | "src_ip"
            | "src_port"
            | "srql_query"
            | "status"
            | "summary"
            | "target"
            | "title"
            | "trace_id"
            | "type"
            | "uid"
            | "vendor"
            | "version"
            | "os.name"
            | "os.version"
            | "os.type"
            | "hw_info.serial_number"
            | "hw_info.cpu_type"
            | "hw_info.cpu_architecture"
    )
}
