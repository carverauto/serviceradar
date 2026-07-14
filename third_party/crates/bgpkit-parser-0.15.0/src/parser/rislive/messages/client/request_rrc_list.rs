use crate::rislive::messages::RisLiveClientMessage;
use serde::Serialize;

#[derive(Default, Debug)]
pub struct RequestRrcList {
    data: Vec<String>,
}

impl Serialize for RequestRrcList {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.data.serialize(serializer)
    }
}

impl RequestRrcList {
    pub fn new(rrc_list: Vec<String>) -> Self {
        Self { data: rrc_list }
    }
}

impl RisLiveClientMessage for RequestRrcList {
    fn msg_type(&self) -> &'static str {
        "request_rrc_list"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_request_rrc_list() {
        let rrc_list = RequestRrcList::new(vec!["rrc00".to_string(), "rrc01".to_string()]);

        println!("{}", rrc_list.to_json_string());
    }
}
