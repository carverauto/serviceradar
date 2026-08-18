use super::fields::{DeviceGroupField, SUPPORTED_GROUP_FIELDS};
use crate::error::{Result, ServiceError};

#[derive(Debug, Clone)]
pub(in crate::query::devices) struct DeviceStatsSpec {
    pub(in crate::query::devices) alias: String,
    pub(in crate::query::devices) group_fields: Vec<DeviceGroupField>,
}

pub(in crate::query::devices) fn parse_stats_spec(
    raw: Option<&str>,
) -> Result<Option<DeviceStatsSpec>> {
    let raw = match raw {
        Some(raw) if !raw.trim().is_empty() => raw.trim(),
        _ => return Ok(None),
    };

    let tokens: Vec<&str> = raw.split_whitespace().collect();
    if tokens.len() < 3 {
        return Err(ServiceError::InvalidRequest(
            "stats expressions must be of the form 'count() as alias'".into(),
        ));
    }

    if !tokens[0].eq_ignore_ascii_case("count()") || !tokens[1].eq_ignore_ascii_case("as") {
        return Err(ServiceError::InvalidRequest(
            "devices stats only support count()".into(),
        ));
    }

    let alias = tokens[2]
        .trim_matches('"')
        .trim_matches('\'')
        .to_lowercase();

    if alias.is_empty()
        || alias
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }

    let mut group_fields = Vec::new();
    if tokens.len() >= 5 {
        if !tokens[3].eq_ignore_ascii_case("by") {
            return Err(ServiceError::InvalidRequest(
                "expected 'by <field>' after stats alias".into(),
            ));
        }
        group_fields = parse_group_fields(tokens[4])?;
    } else if tokens.len() > 3 {
        return Err(ServiceError::InvalidRequest(
            "expected 'by <field>' after stats alias".into(),
        ));
    }

    Ok(Some(DeviceStatsSpec {
        alias,
        group_fields,
    }))
}

fn parse_group_fields(raw: &str) -> Result<Vec<DeviceGroupField>> {
    let fields: Vec<DeviceGroupField> = raw
        .split(',')
        .map(str::trim)
        .filter(|field| !field.is_empty())
        .map(parse_group_field)
        .collect::<Result<Vec<_>>>()?;

    if fields.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "expected at least one stats group field".into(),
        ));
    }

    Ok(fields)
}

fn parse_group_field(raw: &str) -> Result<DeviceGroupField> {
    DeviceGroupField::from_str(raw).ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "unsupported stats group field '{raw}'. Supported fields: {SUPPORTED_GROUP_FIELDS}"
        ))
    })
}
