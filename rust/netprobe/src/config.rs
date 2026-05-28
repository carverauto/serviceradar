use std::collections::HashSet;

use serde::Deserialize;
use thiserror::Error;

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub capture_interfaces: Vec<String>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum AllowlistError {
    #[error("capture interface 'any' is not allowed")]
    AnyInterface,
    #[error("empty capture interface entries are not allowed")]
    EmptyInterface,
    #[error("wildcard capture interfaces are not allowed")]
    Wildcard,
    #[error("capture interface '{0}' is not allowlisted")]
    #[allow(dead_code)]
    NotAllowlisted(String),
}

impl Default for Config {
    fn default() -> Self {
        Self {
            enabled: true,
            capture_interfaces: Vec::new(),
        }
    }
}

impl Config {
    pub fn validate_capture_interfaces(&self) -> Result<(), AllowlistError> {
        validate_capture_interfaces(&self.capture_interfaces)
    }

    #[allow(dead_code)]
    pub fn validate_interface(&self, interface: &str) -> Result<(), AllowlistError> {
        validate_interface(&self.capture_interfaces, interface)
    }
}

pub fn validate_capture_interfaces(interfaces: &[String]) -> Result<(), AllowlistError> {
    for interface in interfaces {
        if interface.trim().is_empty() {
            return Err(AllowlistError::EmptyInterface);
        }

        if interface == "any" {
            return Err(AllowlistError::AnyInterface);
        }

        if interface.contains('*') {
            return Err(AllowlistError::Wildcard);
        }
    }

    Ok(())
}

#[allow(dead_code)]
pub fn validate_interface(allowlist: &[String], interface: &str) -> Result<(), AllowlistError> {
    if interface.trim().is_empty() {
        return Err(AllowlistError::EmptyInterface);
    }

    if interface == "any" {
        return Err(AllowlistError::AnyInterface);
    }

    if interface.contains('*') {
        return Err(AllowlistError::Wildcard);
    }

    let allowed: HashSet<&str> = allowlist.iter().map(String::as_str).collect();
    if allowed.contains(interface) {
        Ok(())
    } else {
        Err(AllowlistError::NotAllowlisted(interface.to_string()))
    }
}

fn default_enabled() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::{validate_capture_interfaces, validate_interface, AllowlistError};

    #[test]
    fn rejects_any_interface() {
        let allowlist = vec!["eth0".to_string(), "lo".to_string()];

        assert_eq!(
            validate_interface(&allowlist, "any"),
            Err(AllowlistError::AnyInterface)
        );
    }

    #[test]
    fn rejects_wildcards() {
        let allowlist = vec!["eth0".to_string()];

        assert_eq!(
            validate_interface(&allowlist, "eth*"),
            Err(AllowlistError::Wildcard)
        );
    }

    #[test]
    fn rejects_empty_entries() {
        let allowlist = vec!["eth0".to_string(), " ".to_string()];

        assert_eq!(
            validate_capture_interfaces(&allowlist),
            Err(AllowlistError::EmptyInterface)
        );
    }

    #[test]
    fn rejects_not_allowlisted_interfaces() {
        let allowlist = vec!["eth0".to_string()];

        assert_eq!(
            validate_interface(&allowlist, "enp0s1"),
            Err(AllowlistError::NotAllowlisted("enp0s1".to_string()))
        );
    }

    #[test]
    fn accepts_allowlisted_interface() {
        let allowlist = vec!["eth0".to_string()];

        assert_eq!(validate_interface(&allowlist, "eth0"), Ok(()));
    }

    #[test]
    fn validates_empty_capture_allowlist() {
        assert_eq!(validate_capture_interfaces(&[]), Ok(()));
    }

    #[test]
    fn validates_capture_allowlist_entries() {
        let allowlist = vec!["eth0".to_string(), "enp0s1".to_string()];

        assert_eq!(validate_capture_interfaces(&allowlist), Ok(()));
    }

    #[test]
    fn rejects_any_in_capture_allowlist() {
        let allowlist = vec!["any".to_string()];

        assert_eq!(
            validate_capture_interfaces(&allowlist),
            Err(AllowlistError::AnyInterface)
        );
    }
}
