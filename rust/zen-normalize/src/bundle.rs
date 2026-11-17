//! The versioned rule bundle core publishes for collectors.
//!
//! A bundle names the stream and subject it applies to and carries every rule
//! in evaluation order, each as the JDM text to compile. Its digest covers all
//! of that, so two bundles with one digest normalize identically, and a reader
//! can reject a document that was altered or truncated.

use crate::{Error, RuleSet};
use serde::Deserialize;
use sha2::{Digest, Sha256};

pub const BUNDLE_SCHEMA: &str = "serviceradar.zen.ruleset.v1";

#[derive(Debug, thiserror::Error)]
pub enum BundleError {
    #[error("invalid Zen rule bundle: {0}")]
    Document(serde_json::Error),
    #[error("unsupported Zen rule bundle schema {0:?}")]
    Schema(String),
    #[error("Zen rule bundle declares digest {declared} but its content has {computed}")]
    Digest { declared: String, computed: String },
    #[error("Zen rule bundle is for stream {stream_name:?} subject {subject:?}")]
    Scope {
        stream_name: String,
        subject: String,
    },
    #[error(transparent)]
    Rules(#[from] Error),
}

#[derive(Deserialize)]
struct Document {
    schema: String,
    stream_name: String,
    subject: String,
    rules: Vec<Rule>,
    digest: String,
}

#[derive(Deserialize)]
struct Rule {
    key: String,
    jdm: String,
}

/// A bundle whose digest matched and whose rules all compiled.
#[derive(Clone)]
pub struct RuleBundle {
    pub stream_name: String,
    pub subject: String,
    /// Identifies this exact ordered content; the ruleset version.
    pub digest: String,
    pub rules: RuleSet,
}

impl RuleBundle {
    /// Accepts a bundle only as a whole. A bundle with no rules is valid.
    pub fn parse(document: &[u8]) -> Result<Self, BundleError> {
        let document: Document = serde_json::from_slice(document).map_err(BundleError::Document)?;
        if document.schema != BUNDLE_SCHEMA {
            return Err(BundleError::Schema(document.schema));
        }
        let rules: Vec<(&str, &str)> = document
            .rules
            .iter()
            .map(|rule| (rule.key.as_str(), rule.jdm.as_str()))
            .collect();
        let computed = bundle_digest(&document.stream_name, &document.subject, &rules);
        if computed != document.digest {
            return Err(BundleError::Digest {
                declared: document.digest,
                computed,
            });
        }
        Ok(Self {
            rules: RuleSet::compile(&rules)?,
            stream_name: document.stream_name,
            subject: document.subject,
            digest: document.digest,
        })
    }
}

/// SHA-256 over the schema, stream, subject and each rule's key and JDM text
/// in order, every part framed as `<byte length>:<bytes>`.
fn bundle_digest(stream_name: &str, subject: &str, rules: &[(&str, &str)]) -> String {
    let mut hash = Sha256::new();
    let mut part = |bytes: &str| {
        hash.update(bytes.len().to_string());
        hash.update(":");
        hash.update(bytes);
    };
    part(BUNDLE_SCHEMA);
    part(stream_name);
    part(subject);
    for (key, jdm) in rules {
        part(key);
        part(jdm);
    }
    format!("sha256:{}", hex::encode(hash.finalize()))
}
