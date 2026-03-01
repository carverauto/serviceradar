use serde::Serialize;
use super::varbind::Varbind;

#[derive(Serialize)]
pub struct TrapMessage {
    pub source: String,
    pub version: String,
    pub community: String,
    pub varbinds: Vec<Varbind>,
}
