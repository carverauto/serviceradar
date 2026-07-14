//! MRT table dump version 1 and 2 structs
use crate::models::*;
use std::net::IpAddr;

/// TableDump message version 1
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TableDumpMessage {
    pub view_number: u16,
    pub sequence_number: u16,
    pub prefix: NetworkPrefix,
    pub status: u8,
    pub originated_time: u64,
    pub peer_ip: IpAddr,
    pub peer_asn: Asn,
    pub attributes: Attributes,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    #[test]
    fn create_table_dump_message() {
        let table_dump_message = TableDumpMessage {
            view_number: 1,
            sequence_number: 1,
            prefix: NetworkPrefix::from_str("192.0.2.0/24").unwrap(),
            status: 1,
            originated_time: 1,
            peer_ip: IpAddr::from_str("192.0.2.1").unwrap(),
            peer_asn: Asn::new_32bit(1),
            attributes: Attributes::default(),
        };

        assert_eq!(table_dump_message.view_number, 1);
        assert_eq!(table_dump_message.sequence_number, 1);

        let cloned = table_dump_message.clone();
        assert_eq!(cloned, table_dump_message);
    }

    #[test]
    #[cfg(feature = "serde")]
    fn serialize_and_deserialize_table_dump_message() {
        use serde_json;

        let table_dump_message = TableDumpMessage {
            view_number: 1,
            sequence_number: 1,
            prefix: NetworkPrefix::from_str("10.0.2.0/24").unwrap(),
            status: 1,
            originated_time: 1,
            peer_ip: IpAddr::from_str("10.0.2.1").unwrap(),
            peer_asn: Asn::new_32bit(1),
            attributes: Attributes::default(),
        };

        let serialized = serde_json::to_string(&table_dump_message).unwrap();
        let deserialized: TableDumpMessage = serde_json::from_str(&serialized).unwrap();

        assert_eq!(table_dump_message, deserialized);
    }
}
