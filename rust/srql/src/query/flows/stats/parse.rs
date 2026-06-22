use super::*;

pub(in crate::query::flows) fn parse_stats_expr(expr: &str) -> Result<FlowStatsSpec> {
    // Parse: "sum(bytes_total) as total_bytes, sum(packets_total) as packets_total by src_endpoint_ip"
    let trimmed = expr.trim();
    if trimmed.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats expression must be like: sum(bytes_total) as total_bytes".into(),
        ));
    }

    let (agg_part, group_part) = if let Some(idx) = find_ascii_case_insensitive(trimmed, " by ") {
        (&trimmed[..idx], Some(trimmed[idx + 4..].trim()))
    } else {
        (trimmed, None)
    };

    let mut aggregations: Vec<FlowAggregationSpec> = Vec::new();
    for segment in agg_part
        .split(',')
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
    {
        aggregations.push(parse_single_stats_aggregation(segment)?);
    }

    if aggregations.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats expression must include at least one aggregation".into(),
        ));
    }

    // Group-by may include multiple keys separated by commas. We intentionally allow
    // spaces after commas by consuming the remainder of the expression after "by".
    let group_by: Vec<FlowGroupSpec> = if let Some(raw) = group_part {
        let tokens: Vec<&str> = raw
            .split(',')
            .map(|t| t.trim())
            .filter(|t| !t.is_empty())
            .collect();

        let mut out: Vec<FlowGroupSpec> = Vec::with_capacity(tokens.len());
        for token in tokens {
            out.push(FlowGroupSpec::parse(token)?);
        }
        out
    } else {
        Vec::new()
    };

    Ok(FlowStatsSpec {
        aggregations,
        group_by,
    })
}

fn parse_single_stats_aggregation(segment: &str) -> Result<FlowAggregationSpec> {
    let segment = segment.trim();
    let as_idx = find_ascii_case_insensitive(segment, " as ").ok_or_else(|| {
        ServiceError::InvalidRequest("stats expression must include 'as <alias>'".into())
    })?;

    let func_part = segment[..as_idx].trim();
    let alias = segment[as_idx + 4..].trim();

    if alias.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats expression missing alias after 'as'".into(),
        ));
    }

    let open = func_part.find('(').ok_or_else(|| {
        ServiceError::InvalidRequest("invalid stats aggregation expression".into())
    })?;
    let close = func_part.rfind(')').ok_or_else(|| {
        ServiceError::InvalidRequest("invalid stats aggregation expression".into())
    })?;
    if close <= open {
        return Err(ServiceError::InvalidRequest(
            "invalid stats aggregation expression".into(),
        ));
    }

    let func = func_part[..open].trim();
    let field = func_part[open + 1..close].trim();

    let agg_func = FlowAggFunc::from_str(func).ok_or_else(|| {
        ServiceError::InvalidRequest(format!("unsupported aggregation function '{func}'"))
    })?;

    let agg_field = FlowAggField::from_str(field).ok_or_else(|| {
        ServiceError::InvalidRequest(format!("unsupported aggregation field '{field}'"))
    })?;

    // COUNT(*) is the only valid use of "*"
    if agg_field == FlowAggField::Star && !matches!(agg_func, FlowAggFunc::Count) {
        return Err(ServiceError::InvalidRequest(
            "only count(*) is supported for '*'".into(),
        ));
    }

    // Port columns only support count-like aggregates.
    if matches!(
        agg_field,
        FlowAggField::SrcEndpointPort | FlowAggField::DstEndpointPort
    ) && !matches!(agg_func, FlowAggFunc::Count | FlowAggFunc::CountDistinct)
    {
        return Err(ServiceError::InvalidRequest(
            "port fields only support count(...) or count_distinct(...)".into(),
        ));
    }

    // The `time` field is only meaningful as a min/max bound (used to derive
    // the data's covered span for §38.1). Sum/count/avg over a timestamp is
    // nonsensical.
    if matches!(agg_field, FlowAggField::Time)
        && !matches!(agg_func, FlowAggFunc::Min | FlowAggFunc::Max)
    {
        return Err(ServiceError::InvalidRequest(
            "time field only supports min(...) or max(...)".into(),
        ));
    }

    Ok(FlowAggregationSpec {
        agg_func,
        agg_field,
        alias: alias.to_string(),
    })
}

fn find_ascii_case_insensitive(haystack: &str, needle: &str) -> Option<usize> {
    haystack
        .as_bytes()
        .windows(needle.len())
        .position(|window| window.eq_ignore_ascii_case(needle.as_bytes()))
}
