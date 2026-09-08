use super::*;

pub(super) fn apply_snmp_index_filter<'a>(
    query: FlowsQuery<'a>,
    filter: &Filter,
    expr: &str,
    label: &str,
) -> Result<FlowsQuery<'a>> {
    let index_literal = |value: &str| -> Result<i64> {
        let parsed = value
            .parse::<i64>()
            .map_err(|_| ServiceError::InvalidRequest(format!("{label} must be an integer")))?;

        if parsed < 0 {
            return Err(ServiceError::InvalidRequest(format!(
                "{label} must be non-negative"
            )));
        }

        Ok(parsed)
    };

    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = index_literal(filter.value.as_scalar()?)?;
            let predicate = sql::<Bool>(&format!("{expr} = {value}"));
            Ok(if matches!(filter.op, FilterOp::Eq) {
                query.filter(predicate)
            } else {
                query.filter(not(predicate))
            })
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok(query);
            }

            let mut parsed: Vec<String> = Vec::with_capacity(values.len());
            for value in values {
                parsed.push(index_literal(value)?.to_string());
            }

            let predicate = sql::<Bool>(&format!("{expr} IN ({})", parsed.join(", ")));
            Ok(if matches!(filter.op, FilterOp::In) {
                query.filter(predicate)
            } else {
                query.filter(not(predicate))
            })
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{label} filter only supports equality or list matching"
        ))),
    }
}
