use super::builder::ResourceLimits;
use super::errors::{JwtSourceError, LimitKind, MetricsErrorKind};
use super::metrics::MetricsRecorder;
use crate::bundle::jwt::JwtBundleSet;

pub(super) fn validate_limits(
    bundle_set: &JwtBundleSet,
    limits: ResourceLimits,
) -> Result<(), JwtSourceError> {
    if let Some(max_bundles) = limits.max_bundles {
        let actual = bundle_set.len();
        if actual > max_bundles {
            return Err(JwtSourceError::ResourceLimitExceeded {
                kind: LimitKind::MaxBundles,
                limit: max_bundles,
                actual,
            });
        }
    }

    if let Some(max_bundle_jwks_bytes) = limits.max_bundle_jwks_bytes {
        for (_, bundle) in bundle_set.iter() {
            // Definition: sum of JWKS bytes for all authorities in the bundle.
            let actual: usize = bundle
                .jwt_authorities()
                .map(|auth| auth.jwk_json().len())
                .sum();

            if actual > max_bundle_jwks_bytes {
                return Err(JwtSourceError::ResourceLimitExceeded {
                    kind: LimitKind::MaxBundleJwksBytes,
                    limit: max_bundle_jwks_bytes,
                    actual,
                });
            }
        }
    }

    Ok(())
}

/// Validates resource limits and records the appropriate metric if a limit is exceeded.
///
/// This is the single authoritative function for limit validation and metric recording.
/// It ensures that limit violations are recorded exactly once with the correct metric kind.
///
/// # Arguments
///
/// * `bundle_set` - The JWT bundle set to validate
/// * `limits` - The resource limits to enforce
/// * `metrics` - Optional metrics recorder for recording limit violations
///
/// # Returns
///
/// Returns `Ok(())` if all limits are satisfied, or `Err(JwtSourceError::ResourceLimitExceeded)`
/// if any limit is exceeded. When a limit is exceeded, the corresponding metric is recorded
/// (e.g., `LimitMaxBundles`, `LimitMaxBundleJwksBytes`).
pub(super) fn validate_limits_and_record_metric(
    bundle_set: &JwtBundleSet,
    limits: ResourceLimits,
    metrics: Option<&dyn MetricsRecorder>,
) -> Result<(), JwtSourceError> {
    if let Err(e) = validate_limits(bundle_set, limits) {
        if let JwtSourceError::ResourceLimitExceeded { kind, .. } = &e {
            if let Some(m) = metrics {
                m.record_error(metric_kind_for_limit(*kind));
            }
        }
        return Err(e);
    }
    Ok(())
}

/// Maps a `LimitKind` to the corresponding `MetricsErrorKind` for limit violations.
///
/// This is the single authoritative mapping used throughout the codebase to ensure
/// consistent metric recording for limit violations.
pub(super) const fn metric_kind_for_limit(kind: LimitKind) -> MetricsErrorKind {
    match kind {
        LimitKind::MaxBundles => MetricsErrorKind::LimitMaxBundles,
        LimitKind::MaxBundleJwksBytes => MetricsErrorKind::LimitMaxBundleJwksBytes,
    }
}

/// Validates a JWT bundle set for acceptability (limits).
///
/// This is the single authoritative function for bundle set validation used in both
/// initial sync and steady-state updates. It ensures consistent validation logic
/// and correct metric recording.
pub(super) fn validate_bundle_set(
    bundle_set: &JwtBundleSet,
    limits: ResourceLimits,
    metrics: Option<&dyn MetricsRecorder>,
) -> Result<(), JwtSourceError> {
    // Validate limits and record specific limit metrics if exceeded.
    validate_limits_and_record_metric(bundle_set, limits, metrics)?;

    Ok(())
}
