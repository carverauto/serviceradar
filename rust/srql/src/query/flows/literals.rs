use super::*;

pub(super) fn normalize_cidr_literal(input: &str) -> Result<String> {
    let s = input.trim();
    let (ip_raw, prefix_raw) = s
        .split_once('/')
        .ok_or_else(|| ServiceError::InvalidRequest("CIDR must be like 10.0.0.0/24".into()))?;

    let ip: std::net::IpAddr = ip_raw.trim().parse().map_err(|_| {
        ServiceError::InvalidRequest("CIDR must contain a valid IPv4/IPv6 address".into())
    })?;

    let prefix: u8 = prefix_raw.trim().parse().map_err(|_| {
        ServiceError::InvalidRequest("CIDR must contain a valid prefix length".into())
    })?;

    let max = match ip {
        std::net::IpAddr::V4(_) => 32,
        std::net::IpAddr::V6(_) => 128,
    };
    if prefix > max {
        return Err(ServiceError::InvalidRequest(format!(
            "CIDR prefix length must be <= {max}"
        )));
    }

    Ok(format!("{ip}/{prefix}"))
}

pub(super) fn normalize_device_uid_literal(input: &str) -> Result<String> {
    let uid = input.trim();
    let valid = !uid.is_empty()
        && uid
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, ':' | '-' | '_' | '.'));

    if valid {
        Ok(uid.to_string())
    } else {
        Err(ServiceError::InvalidRequest(
            "device_id filter must be a canonical UID-like value".into(),
        ))
    }
}
