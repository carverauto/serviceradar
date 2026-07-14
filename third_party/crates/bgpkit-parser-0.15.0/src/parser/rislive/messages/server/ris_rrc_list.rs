use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct RisRrcList {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ris_rrc_list_serde() {
        let ris_rrc_list = RisRrcList {};

        // serialize RisRrcList
        let serialized = serde_json::to_string(&ris_rrc_list).expect("Failed to serialize");

        // the serialized RisRrcList would be '{}'
        assert_eq!(serialized, "{}");

        // deserialize RisRrcList
        let deserialized: RisRrcList =
            serde_json::from_str(&serialized).expect("Failed to deserialize");

        assert_eq!(ris_rrc_list, deserialized);
    }
}
