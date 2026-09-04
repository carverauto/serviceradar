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
        field: normalize_field_name(field),
        op,
        value: final_value,
    }
}

/// Field names are case-insensitive, but a JSONB sub-key is not.
///
/// `tags.<key>` and `metadata.<key>` address arbitrary keys that ingestion
/// stores with whatever casing the operator used, and Postgres JSONB lookups
/// are case-sensitive -- so lowercasing the key turns `tags.Gate` into a probe
/// for `tags->>'gate'` that silently matches nothing. Only the namespace is
/// folded. Fixed dotted fields (`os.name`, `hw_info.cpu_type`) name real
/// columns and stay fully folded.
pub(super) fn normalize_field_name(field: &str) -> String {
    const DYNAMIC_JSONB_NAMESPACES: [&str; 2] = ["tags", "metadata"];

    if let Some((namespace, key)) = field.split_once('.') {
        let namespace = namespace.to_lowercase();
        if DYNAMIC_JSONB_NAMESPACES.contains(&namespace.as_str()) {
            return format!("{namespace}.{key}");
        }
    }

    field.to_lowercase()
}

fn supports_implicit_like(field: &str) -> bool {
    let field = field.to_ascii_lowercase();
    if field.starts_with("metadata.") || field.starts_with("tags.") {
        return true;
    }

    matches!(
        field.as_str(),
        "activity"
            | "agent_id"
            | "aos_version"
            | "app"
            | "application"
            | "applicability_reason"
            | "architecture"
            | "assessment"
            | "attributes"
            | "authority"
            | "binary_package"
            | "category"
            | "check_name"
            | "classification"
            | "cluster"
            | "collector"
            | "component"
            | "advisory_id"
            | "confidence"
            | "coordinate_type"
            | "coordinate_value"
            | "cpe"
            | "cpe_part"
            | "cpe_product"
            | "cpe_vendor"
            | "cpe_version"
            | "cpes"
            | "cve"
            | "cve_id"
            | "description"
            | "destination"
            | "device"
            | "device_id"
            | "device_ip"
            | "device_uid"
            | "direction"
            | "disposition"
            | "distro"
            | "dst_endpoint_ip"
            | "dst_ip"
            | "dst_port"
            | "due_date"
            | "endpoint_ip"
            | "endpoint_port"
            | "entity"
            | "ecosystem"
            | "error"
            | "event"
            | "event_name"
            | "feed_key"
            | "fixed_version"
            | "freshness"
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
            | "package_identity_key"
            | "package_manager"
            | "package_name"
            | "package_namespace"
            | "package_purl"
            | "package_release"
            | "package_type"
            | "package_version"
            | "parent_span_id"
            | "port"
            | "protocol"
            | "protocol_group"
            | "provider"
            | "purl"
            | "purl_canonical"
            | "ransomware_use"
            | "release"
            | "resource"
            | "root_span_id"
            | "service"
            | "service_name"
            | "service_namespace"
            | "service_type"
            | "severity"
            | "source"
            | "source_package"
            | "source_scope"
            | "source_type"
            | "source_version"
            | "span_id"
            | "src_endpoint_ip"
            | "src_ip"
            | "src_port"
            | "srql_query"
            | "status"
            | "summary"
            | "target"
            | "target_ip"
            | "title"
            | "trace_id"
            | "type"
            | "device_type"
            | "uid"
            | "vendor"
            | "version"
            | "version_scheme"
            | "installed_version"
            | "os.name"
            | "os.version"
            | "os.type"
            | "hw_info.serial_number"
            | "hw_info.cpu_type"
            | "hw_info.cpu_architecture"
            | "vlan_uid"
            | "fact_key"
            | "switch_port_attachment.switch_hostname"
            | "switch_port_attachment.port"
            | "switch_port_attachment.source"
    )
}
