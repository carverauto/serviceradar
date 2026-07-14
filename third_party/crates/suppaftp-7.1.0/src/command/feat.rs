use crate::FtpError;
use crate::types::Features;

/// Parses a FEAT response line from the FTP server.
///
/// RFC is specified [RFC 2389](https://datatracker.ietf.org/doc/html/rfc2389#section-3.2).
///
/// This is the syntax of the FEAT response:
///
/// - no-features: "211 [SP] ..."
/// - features-list: "211-...":
///     - ... "feature-label" [[SP] ["description"]]
///     - "211 END"
///
/// # Arguments
///
/// * `line` - A string slice representing a line from the FEAT response.
///
/// # Returns
///
/// A `Result` containing a tuple with the feature name and an optional description.
pub fn parse_features(lines: &[String]) -> Result<Features, FtpError> {
    // Check if the first line starts with "211 "
    let first_line = lines.first().ok_or(FtpError::BadResponse)?;
    debug!("Parsing features; first line: {first_line}");

    let mut features = Features::with_capacity(lines.len());
    if first_line.starts_with("211-") {
        debug!("Found `211-` - features available");
        // parse list
        for line in lines.iter().skip(1) {
            if line.starts_with("211 ") {
                debug!("Found `211 End` - end of FEAT");
                break;
            }

            parse_feature(line, &mut features)?;
        }
        Ok(features)
    } else if first_line.starts_with("211 ") {
        debug!("Found `211` - no features available");
        // No features available
        Ok(features)
    } else {
        Err(FtpError::BadResponse)
    }
}

/// Parses a single feature line from the FEAT response.
///
/// The line MUST start with a space character (` `) and can have the following syntax:
///
/// - `feature-label` [[SP] ["description"]]
fn parse_feature(line: &str, features: &mut Features) -> Result<(), FtpError> {
    if !line.starts_with(' ') {
        error!("Feature response doesn't start with ` `");
        return Err(FtpError::BadResponse);
    }

    let mut line = line.trim().split(' ');
    let Some(feature_name) = line.next() else {
        error!("Feature line is empty");
        return Err(FtpError::BadResponse);
    };
    let feature_values = match line.collect::<Vec<&str>>().join(" ") {
        values if values.is_empty() => None,
        values => Some(values),
    };
    debug!("found supported feature: {feature_name}: {feature_values:?}");
    features.insert(feature_name.to_string(), feature_values);

    Ok(())
}

/// Checks if the given line is the last line of the FEAT response.
pub fn is_last_line(line: &str) -> bool {
    line.starts_with("211 ")
}

#[cfg(test)]
mod test {

    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_should_parse_no_features() {
        let lines = vec!["211 No features available".to_string()];
        let features = parse_features(&lines).expect("failed to parse features");
        assert!(features.is_empty());
    }

    #[test]
    fn test_should_parse_features() {
        let lines = vec![
            "211-Features:".to_string(),
            " MLST size*;create;modify*;perm;media-type".to_string(),
            " SIZE".to_string(),
            " COMPRESSION".to_string(),
            "211 END".to_string(),
        ];
        let features = parse_features(&lines).expect("failed to parse features");
        assert_eq!(features.len(), 3);
        assert!(features.contains_key("MLST"));
        assert_eq!(
            features
                .get("MLST")
                .as_ref()
                .expect("no MLST")
                .as_deref()
                .expect("no value for MLST"),
            "size*;create;modify*;perm;media-type"
        );
        assert!(features.contains_key("SIZE"));
        assert_eq!(features.get("SIZE"), Some(&None));
        assert!(features.contains_key("COMPRESSION"));
        assert_eq!(features.get("COMPRESSION"), Some(&None));
    }

    #[test]
    fn test_should_not_parse_invalid_features() {
        let lines = vec![
            "211-Features:".to_string(),
            "Invalid feature line".to_string(),
        ];
        let result = parse_features(&lines);
        assert!(result.is_err(), "Expected error for invalid feature line");
        assert!(matches!(result.unwrap_err(), FtpError::BadResponse));
    }
}
