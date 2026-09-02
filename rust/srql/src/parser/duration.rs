use crate::{
    error::{Result, ServiceError},
    parser::DownsampleAgg,
};

const MAX_DOWNSAMPLE_BUCKET_SECS: i64 = 31 * 24 * 60 * 60;

pub(super) fn parse_bucket_seconds(raw: &str) -> Result<i64> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "bucket requires a duration like 5m, 1h".into(),
        ));
    }

    let raw = raw.to_lowercase();
    let Some((unit_start, unit)) = raw.char_indices().next_back() else {
        return Err(ServiceError::InvalidRequest(
            "bucket requires a duration like 5m, 1h".into(),
        ));
    };
    let number_part = &raw[..unit_start];
    let value = number_part
        .parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest("bucket duration must be an integer".into()))?;

    if value <= 0 {
        return Err(ServiceError::InvalidRequest(
            "bucket duration must be positive".into(),
        ));
    }

    let multiplier = match unit {
        's' => 1,
        'm' => 60,
        'h' => 60 * 60,
        'd' => 24 * 60 * 60,
        _ => {
            return Err(ServiceError::InvalidRequest(
                "bucket supports only s|m|h|d suffixes".into(),
            ));
        }
    };

    let seconds = value.checked_mul(multiplier).ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "bucket duration must be between 1s and {}d",
            MAX_DOWNSAMPLE_BUCKET_SECS / (24 * 60 * 60)
        ))
    })?;
    if seconds <= 0 || seconds > MAX_DOWNSAMPLE_BUCKET_SECS {
        return Err(ServiceError::InvalidRequest(format!(
            "bucket duration must be between 1s and {}d",
            MAX_DOWNSAMPLE_BUCKET_SECS / (24 * 60 * 60)
        )));
    }
    Ok(seconds)
}

pub(super) fn parse_downsample_agg(raw: &str) -> Result<DownsampleAgg> {
    match raw.trim().to_lowercase().as_str() {
        "avg" | "mean" => Ok(DownsampleAgg::Avg),
        "min" => Ok(DownsampleAgg::Min),
        "max" => Ok(DownsampleAgg::Max),
        "sum" => Ok(DownsampleAgg::Sum),
        "count" => Ok(DownsampleAgg::Count),
        "rate" => Ok(DownsampleAgg::Rate),
        "rate_sum" => Ok(DownsampleAgg::RateSum),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported agg '{other}' (use avg|min|max|sum|count|rate|rate_sum)"
        ))),
    }
}

pub(super) fn normalize_optional_string(raw: &str) -> Option<String> {
    let value = raw.trim().trim_matches('"').trim_matches('\'').trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}
