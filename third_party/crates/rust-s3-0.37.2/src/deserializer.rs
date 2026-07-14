use serde::de::*;

pub fn bool_deserializer<'de, D>(d: D) -> Result<bool, D::Error>
where
    D: Deserializer<'de>,
{
    let s = String::deserialize(d)?;
    match &s[..] {
        "true" => Ok(true),
        "false" => Ok(false),
        other => Err(D::Error::custom(format!(
            "got {}, but expected `true` or `false`",
            other
        ))),
    }
}
