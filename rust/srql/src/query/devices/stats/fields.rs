#[derive(Debug, Clone, Copy, PartialEq)]
pub(in crate::query::devices) enum DeviceGroupField {
    Type,
    VendorName,
    RiskLevel,
    IsAvailable,
    IsActive,
    GatewayId,
}

impl DeviceGroupField {
    pub(super) fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "type" | "device_type" => Some(Self::Type),
            "vendor_name" | "vendor" => Some(Self::VendorName),
            "risk_level" | "risk" => Some(Self::RiskLevel),
            "is_available" | "available" => Some(Self::IsAvailable),
            "is_active" | "active" => Some(Self::IsActive),
            "gateway_id" | "gateway" => Some(Self::GatewayId),
            _ => None,
        }
    }

    pub(super) fn column(&self) -> &'static str {
        match self {
            Self::Type => "COALESCE(NULLIF(trim(type), ''), 'Unknown')",
            Self::VendorName => "COALESCE(vendor_name, 'Unknown')",
            Self::RiskLevel => "COALESCE(risk_level, 'Unknown')",
            Self::IsAvailable => "COALESCE(is_available, false)",
            Self::IsActive => "COALESCE(is_active, true)",
            Self::GatewayId => "gateway_id",
        }
    }

    pub(super) fn response_key(&self) -> &'static str {
        match self {
            Self::Type => "type",
            Self::VendorName => "vendor_name",
            Self::RiskLevel => "risk_level",
            Self::IsAvailable => "is_available",
            Self::IsActive => "is_active",
            Self::GatewayId => "gateway_id",
        }
    }
}
