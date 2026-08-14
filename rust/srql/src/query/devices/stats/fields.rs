use super::super::filters::is_valid_jsonb_key;

/// JSONB columns on `ocsf_devices` whose arbitrary sub-keys can be grouped on.
/// These mirror the sub-key filters in `filters/jsonb.rs`.
const JSONB_GROUP_COLUMNS: [&str; 2] = ["tags", "metadata"];

pub(in crate::query::devices) const SUPPORTED_GROUP_FIELDS: &str = "type, vendor_name, risk_level, is_available, is_active, gateway_id, tags.<key>, metadata.<key>";

#[derive(Debug, Clone, PartialEq)]
pub(in crate::query::devices) enum DeviceGroupField {
    Type,
    VendorName,
    RiskLevel,
    IsAvailable,
    IsActive,
    GatewayId,
    /// A sub-key of a JSONB column, e.g. `tags.gate`. `key` is always validated
    /// by `is_valid_jsonb_key` before construction because it is interpolated
    /// into SQL rather than bound as a parameter.
    Jsonb {
        column: &'static str,
        key: String,
    },
}

impl DeviceGroupField {
    pub(super) fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "type" | "device_type" => return Some(Self::Type),
            "vendor_name" | "vendor" => return Some(Self::VendorName),
            "risk_level" | "risk" => return Some(Self::RiskLevel),
            "is_available" | "available" => return Some(Self::IsAvailable),
            "is_active" | "active" => return Some(Self::IsActive),
            "gateway_id" | "gateway" => return Some(Self::GatewayId),
            _ => {}
        }

        // `tags.<key>` / `metadata.<key>`. Only the first `.` separates the
        // column from the key; `is_valid_jsonb_key` rejects any remaining dot,
        // so nested paths are refused rather than silently truncated.
        //
        // Only the column name is case-folded. JSONB keys are case-sensitive in
        // Postgres and tag ingestion preserves whatever casing the operator
        // used, so lowercasing `tags.Gate` here would read `tags->>'gate'` and
        // bucket every real "Gate" row under 'Unknown'.
        let (column, key) = s.split_once('.')?;
        let column_lowered = column.to_lowercase();
        let column = JSONB_GROUP_COLUMNS
            .iter()
            .find(|candidate| **candidate == column_lowered)?;

        if !is_valid_jsonb_key(key) {
            return None;
        }

        Some(Self::Jsonb {
            column,
            key: key.to_string(),
        })
    }

    pub(super) fn column(&self) -> String {
        match self {
            Self::Type => "COALESCE(NULLIF(trim(type), ''), 'Unknown')".to_string(),
            Self::VendorName => "COALESCE(vendor_name, 'Unknown')".to_string(),
            Self::RiskLevel => "COALESCE(risk_level, 'Unknown')".to_string(),
            Self::IsAvailable => "COALESCE(is_available, false)".to_string(),
            Self::IsActive => "COALESCE(is_active, true)".to_string(),
            Self::GatewayId => "gateway_id".to_string(),
            // Devices missing the key group together under 'Unknown' rather
            // than being dropped, matching how `type` and `vendor_name` behave.
            Self::Jsonb { column, key } => {
                format!("COALESCE({column}->>'{key}', 'Unknown')")
            }
        }
    }

    pub(super) fn response_key(&self) -> String {
        match self {
            Self::Type => "type".to_string(),
            Self::VendorName => "vendor_name".to_string(),
            Self::RiskLevel => "risk_level".to_string(),
            Self::IsAvailable => "is_available".to_string(),
            Self::IsActive => "is_active".to_string(),
            Self::GatewayId => "gateway_id".to_string(),
            Self::Jsonb { column, key } => format!("{column}.{key}"),
        }
    }

    pub(super) fn matches_order_field(&self, field: &str) -> bool {
        match self {
            // Arbitrary JSONB keys are case-sensitive, so `tags.Gate` and
            // `tags.gate` are different sort targets just as they are
            // different filter and GROUP BY targets.
            Self::Jsonb { .. } => self.response_key() == field,
            _ => self.response_key().eq_ignore_ascii_case(field),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_scalar_group_fields() {
        assert_eq!(
            DeviceGroupField::from_str("type"),
            Some(DeviceGroupField::Type)
        );
        assert_eq!(
            DeviceGroupField::from_str("VENDOR"),
            Some(DeviceGroupField::VendorName)
        );
    }

    #[test]
    fn parses_jsonb_group_fields() {
        let field = DeviceGroupField::from_str("tags.gate").expect("tags.gate should parse");
        assert_eq!(field.column(), "COALESCE(tags->>'gate', 'Unknown')");
        assert_eq!(field.response_key(), "tags.gate");

        let field =
            DeviceGroupField::from_str("metadata.integration_type").expect("metadata should parse");
        assert_eq!(
            field.column(),
            "COALESCE(metadata->>'integration_type', 'Unknown')"
        );

        let upper = DeviceGroupField::from_str("tags.Gate").expect("tags.Gate should parse");
        assert!(upper.matches_order_field("tags.Gate"));
        assert!(!upper.matches_order_field("tags.gate"));
    }

    #[test]
    fn rejects_unknown_jsonb_columns() {
        assert_eq!(DeviceGroupField::from_str("os.name"), None);
        assert_eq!(DeviceGroupField::from_str("hw_info.serial_number"), None);
    }

    #[test]
    fn rejects_keys_that_could_break_out_of_the_sql_literal() {
        for key in [
            "tags.",
            "tags.a'b",
            "tags.a; DROP TABLE ocsf_devices --",
            "tags.a.b",
            "tags.a b",
        ] {
            assert_eq!(
                DeviceGroupField::from_str(key),
                None,
                "{key} must be rejected"
            );
        }
    }

    #[test]
    fn rejects_keys_longer_than_the_jsonb_key_limit() {
        let long_key = format!("tags.{}", "a".repeat(65));
        assert_eq!(DeviceGroupField::from_str(&long_key), None);
    }
}
