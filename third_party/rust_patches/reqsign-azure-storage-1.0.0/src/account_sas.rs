use reqsign_core::Result;

use reqsign_core::hash;
use reqsign_core::time;
use reqsign_core::time::DateTime;

/// The default parameters that make up a SAS token
/// https://learn.microsoft.com/en-us/rest/api/storageservices/create-account-sas#specify-the-account-sas-parameters
const ACCOUNT_SAS_VERSION: &str = "2018-11-09";
const ACCOUNT_SAS_RESOURCE: &str = "bqtf";
const ACCOUNT_SAS_RESOURCE_TYPE: &str = "sco";
const ACCOUNT_SAS_PERMISSIONS: &str = "rwdlacu";

pub struct AccountSharedAccessSignature {
    account: String,
    key: String,
    version: String,
    resource: String,
    resource_type: String,
    permissions: String,
    expiry: DateTime,
    start: Option<DateTime>,
    ip: Option<String>,
    protocol: Option<String>,
}

impl AccountSharedAccessSignature {
    /// Create a SAS token signer with default parameters
    pub fn new(account: String, key: String, expiry: DateTime) -> Self {
        Self {
            account,
            key,
            expiry,
            start: None,
            ip: None,
            protocol: None,
            version: ACCOUNT_SAS_VERSION.to_string(),
            resource: ACCOUNT_SAS_RESOURCE.to_string(),
            resource_type: ACCOUNT_SAS_RESOURCE_TYPE.to_string(),
            permissions: ACCOUNT_SAS_PERMISSIONS.to_string(),
        }
    }

    // Azure documentation: https://learn.microsoft.com/en-us/rest/api/storageservices/create-account-sas#construct-the-signature-string
    fn signature(&self) -> Result<String> {
        let string_to_sign = format!(
            "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n",
            self.account,
            self.permissions,
            self.resource,
            self.resource_type,
            self.start
                .as_ref()
                .map_or("".to_string(), |v| urlencoded(time::format_rfc3339(*v))),
            time::format_rfc3339(self.expiry),
            self.ip.clone().unwrap_or_default(),
            self.protocol
                .as_ref()
                .map_or("".to_string(), |v| v.to_string()),
            self.version,
        );

        let decode_content = hash::base64_decode(self.key.clone().as_str())?;

        Ok(hash::base64_hmac_sha256(
            &decode_content,
            string_to_sign.as_bytes(),
        ))
    }

    /// [Example](https://docs.microsoft.com/rest/api/storageservices/create-service-sas#service-sas-example) from Azure documentation.
    pub fn token(&self) -> Result<Vec<(String, String)>> {
        let mut elements: Vec<(String, String)> = vec![
            ("sv".to_string(), self.version.to_string()),
            ("ss".to_string(), self.resource.to_string()),
            ("srt".to_string(), self.resource_type.to_string()),
            (
                "se".to_string(),
                urlencoded(time::format_rfc3339(self.expiry)),
            ),
            ("sp".to_string(), self.permissions.to_string()),
        ];

        if let Some(start) = &self.start {
            elements.push(("st".to_string(), urlencoded(time::format_rfc3339(*start))))
        }
        if let Some(ip) = &self.ip {
            elements.push(("sip".to_string(), ip.to_string()))
        }
        if let Some(protocol) = &self.protocol {
            elements.push(("spr".to_string(), protocol.to_string()))
        }

        let sig = AccountSharedAccessSignature::signature(self)?;
        elements.push(("sig".to_string(), urlencoded(sig)));

        Ok(elements)
    }
}

fn urlencoded(s: String) -> String {
    form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use super::*;

    fn test_time() -> DateTime {
        DateTime::from_str("2022-03-01T08:12:34Z").unwrap()
    }

    #[test]
    fn test_can_generate_sas_token() {
        let key = hash::base64_encode("key".as_bytes());
        let expiry = test_time() + chrono::TimeDelta::try_minutes(5).expect("in bounds");
        let sign = AccountSharedAccessSignature::new("account".to_string(), key, expiry);
        let token_content = sign.token().expect("token decode failed");
        let token = token_content
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<String>>()
            .join("&");

        assert_eq!(token, "sv=2018-11-09&ss=bqtf&srt=sco&se=2022-03-01T08%3A17%3A34Z&sp=rwdlacu&sig=jgK9nDUT0ntH%2Fp28LPs0jzwxsk91W6hePLPlfrElv4k%3D");
    }
}
