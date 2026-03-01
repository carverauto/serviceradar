use serde::Serialize;

#[derive(Serialize)]
pub struct Varbind {
    pub oid: String,
    pub value: String,
}
