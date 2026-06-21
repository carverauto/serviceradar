use crate::parser::{OrderClause, OrderDirection};

pub(super) fn build_order_clause(
    order: &[OrderClause],
    stable_history_order: bool,
    alias: Option<&str>,
) -> Option<String> {
    let mut clauses = Vec::new();
    let mut ordered_fields = Vec::new();

    for clause in order {
        let (field, column) = match clause.field.as_str() {
            "timestamp" => ("timestamp", "timestamp"),
            "device_ip" => ("device_ip", "device_ip"),
            "device_id" => ("device_id", "device_id"),
            "interface_uid" => ("interface_uid", "interface_uid"),
            "if_name" => ("if_name", "if_name"),
            "if_descr" => ("if_descr", "if_descr"),
            "if_index" => ("if_index", "if_index"),
            "if_type" => ("if_type", "if_type"),
            "if_type_name" => ("if_type_name", "if_type_name"),
            "interface_kind" => ("interface_kind", "interface_kind"),
            "speed_bps" | "if_speed" | "speed" => ("speed_bps", "speed_bps"),
            "mtu" => ("mtu", "mtu"),
            _ => continue,
        };

        let direction = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };

        clauses.push(format!("{} {direction}", column_ref(alias, column)));
        ordered_fields.push(field);
    }

    if clauses.is_empty() {
        clauses.push(format!("{} DESC", column_ref(alias, "timestamp")));
        clauses.push(format!("{} DESC", column_ref(alias, "created_at")));
        ordered_fields.push("timestamp");
    }

    if stable_history_order {
        append_interface_history_tiebreakers(&mut clauses, &ordered_fields, alias);
    }

    Some(format!("ORDER BY {}", clauses.join(", ")))
}

fn append_interface_history_tiebreakers(
    clauses: &mut Vec<String>,
    ordered_fields: &[&str],
    alias: Option<&str>,
) {
    if !ordered_fields.contains(&"timestamp") {
        clauses.push(format!("{} DESC", column_ref(alias, "timestamp")));
    }
    if !ordered_fields.contains(&"device_id") {
        clauses.push(format!("{} ASC", column_ref(alias, "device_id")));
    }
    if !ordered_fields.contains(&"interface_uid") {
        clauses.push(format!("{} ASC", column_ref(alias, "interface_uid")));
    }
}

fn column_ref(alias: Option<&str>, column: &str) -> String {
    match alias {
        Some(alias) => format!("{alias}.{column}"),
        None => column.to_string(),
    }
}
