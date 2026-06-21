use crate::parser::{OrderClause, OrderDirection};

pub(super) fn parse_order(raw: &str) -> Vec<OrderClause> {
    raw.split(',')
        .filter_map(|segment| {
            let trimmed = segment.trim();
            if trimmed.is_empty() {
                return None;
            }

            let mut parts = trimmed.splitn(3, ':');
            let field = parts.next()?.trim().to_lowercase();
            let direction = parts
                .next()
                .map(|dir| match dir.to_lowercase().as_str() {
                    "asc" => OrderDirection::Asc,
                    "desc" => OrderDirection::Desc,
                    _ => OrderDirection::Desc,
                })
                .unwrap_or(OrderDirection::Desc);

            Some(OrderClause { field, direction })
        })
        .collect()
}
