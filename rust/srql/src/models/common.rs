//! Shared helpers for deriving device identity from row attributes.

use serde_json::Value;

const DEVICE_IDENTITY_KEYS: &[&str] = &[
    "serviceradar.device.uid",
    "serviceradar.device_uid",
    "service_radar.device_uid",
    "service_radar.device.uid",
    "serviceradar.device_id",
    "service_radar.device_id",
    "device_id",
    "device_uid",
    "source_device_uid",
    "target_device_uid",
    "uid",
    "id",
];

pub(crate) fn source_device_uid_from_attributes(
    resource_attributes: Option<&str>,
    attributes: Option<&str>,
) -> Option<String> {
    resource_attributes
        .and_then(|raw| string_field_from_json(raw, DEVICE_IDENTITY_KEYS))
        .or_else(|| attributes.and_then(|raw| string_field_from_json(raw, DEVICE_IDENTITY_KEYS)))
}

pub(crate) fn source_device_uid_from_json_values(values: &[&Value]) -> Option<String> {
    values
        .iter()
        .find_map(|value| {
            DEVICE_IDENTITY_KEYS
                .iter()
                .find_map(|key| extract_json_string(value, key))
        })
        .filter(|value| !value.trim().is_empty())
}

fn string_field_from_json(raw: &str, keys: &[&str]) -> Option<String> {
    let value: Value = serde_json::from_str(raw).ok()?;

    keys.iter()
        .find_map(|key| extract_json_string(&value, key))
        .filter(|value| !value.trim().is_empty())
}

fn extract_json_string(value: &Value, key: &str) -> Option<String> {
    if let Value::Object(map) = value {
        if let Some(Value::String(raw)) = map.get(key) {
            return Some(raw.clone());
        }

        let mut current = value;
        for part in key.split('.') {
            current = current.get(part)?;
        }

        match current {
            Value::String(raw) => Some(raw.clone()),
            Value::Number(number) => Some(number.to_string()),
            _ => None,
        }
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn source_device_uid_prefers_service_radar_metadata_over_ocsf_device_uid() {
        let metadata = json!({
            "service_radar": {
                "device_uid": "sr:canonical-device"
            }
        });
        let device = json!({
            "uid": "scanner-local-host",
            "hostname": "worker-1"
        });

        assert_eq!(
            source_device_uid_from_json_values(&[&metadata, &device]),
            Some("sr:canonical-device".to_owned())
        );
    }

    #[test]
    fn source_device_uid_reads_legacy_serviceradar_key() {
        let metadata = json!({
            "serviceradar": {
                "device": {
                    "uid": "sr:legacy-device"
                }
            }
        });

        assert_eq!(
            source_device_uid_from_json_values(&[&metadata]),
            Some("sr:legacy-device".to_owned())
        );
    }
}
