//! Crypto provider initialization for rustls.
//!
//! This module provides a helper function to ensure that rustls has a default
//! crypto provider installed. It attempts to use AWS-LC first, falling back
//! to ring if necessary.

use crate::OneIoError;

/// Ensures that a default crypto provider is installed for rustls.
///
/// This function checks if a crypto provider is already installed, and if not,
/// attempts to install one automatically:
///
/// 1. First tries AWS-LC if available (when rustls is compiled with aws_lc_rs support)
/// 2. Falls back to ring if AWS-LC is not available or installation fails
/// 3. Returns an error if no provider is available
///
/// This should be called early in your application startup, or before any HTTPS/S3
/// operations. It's safe to call multiple times - if a provider is already installed,
/// this function does nothing.
///
/// # Errors
///
/// Returns a [`OneIoError::NotSupported`] if:
/// - No crypto provider is available in the build
/// - Provider installation fails
///
/// # Examples
///
/// ```rust
/// use oneio::crypto::ensure_default_provider;
///
/// // Call this once at startup
/// ensure_default_provider().expect("Failed to initialize crypto provider");
///
/// // Now you can safely use HTTPS/S3 operations
/// let content = oneio::read_to_string("https://example.com/data.txt");
/// ```
///
/// For other crates in your workspace that use oneio:
/// ```rust,ignore
/// // In your binary's main.rs or lib.rs
/// fn main() {
///     oneio::crypto::ensure_default_provider()
///         .expect("Failed to initialize crypto provider");
///     
///     // Rest of your application...
/// }
/// ```
#[cfg(feature = "rustls")]
pub fn ensure_default_provider() -> Result<(), OneIoError> {
    // Check if a provider is already installed
    #[cfg(feature = "rustls")]
    {
        if rustls_sys::crypto::CryptoProvider::get_default().is_some() {
            return Ok(());
        }

        // Try AWS-LC first (if available)
        match rustls_sys::crypto::aws_lc_rs::default_provider().install_default() {
            Ok(_) => return Ok(()),
            Err(_) => {
                // If installation failed because a provider is already installed, that's OK
                if rustls_sys::crypto::CryptoProvider::get_default().is_some() {
                    return Ok(());
                }
                // AWS-LC installation failed for another reason, try ring
            }
        }

        // Try ring as fallback
        match rustls_sys::crypto::ring::default_provider().install_default() {
            Ok(_) => Ok(()),
            Err(e) => {
                // If installation failed because a provider is already installed, that's OK
                if rustls_sys::crypto::CryptoProvider::get_default().is_some() {
                    return Ok(());
                }
                // Both failed and no provider is installed
                Err(OneIoError::NotSupported(format!(
                    "Failed to install rustls crypto provider: {:?}",
                    e
                )))
            }
        }
    }

    #[cfg(not(feature = "rustls"))]
    {
        // If rustls is not enabled, that's fine - we're not using it
        Ok(())
    }
}

/// Ensures that a default crypto provider is installed for rustls.
///
/// This is a no-op when rustls feature is not enabled.
#[cfg(not(feature = "rustls"))]
pub fn ensure_default_provider() -> Result<(), OneIoError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ensure_default_provider() {
        // Should succeed whether provider is installed or not
        let result = ensure_default_provider();
        assert!(result.is_ok(), "ensure_default_provider should succeed");
    }

    #[cfg(feature = "rustls")]
    #[test]
    fn test_provider_installed() {
        // After calling ensure_default_provider, a provider should be available
        ensure_default_provider().unwrap();
        assert!(
            rustls_sys::crypto::CryptoProvider::get_default().is_some(),
            "A crypto provider should be installed"
        );
    }
}
