use crate::{MessageType, Pdu, Value};

use super::{pdu, snmp, Oid};
use super::{AsnReader, Error, Varbinds, Version};
use asn1_rs::oid;

#[test]
fn build_get_many_pdu() {
    let mut pdu = pdu::Buf::default();
    pdu::build_get_many(
        Version::V2C,
        b"tyS0n43d",
        1_251_699_619,
        &[
            &Oid::from(&[1, 3, 6, 1, 2, 1, 1, 1, 0]).unwrap(),
            &Oid::from(&[1, 3, 6, 1, 2, 1, 1, 2, 0]).unwrap(),
        ],
        &mut pdu,
        #[cfg(feature = "v3")]
        None,
    )
    .unwrap();

    let expected = &[
        48, 57, // SEQUENCE (Message), length 51
        2, 1, 1, // INTEGER (Version = 1 for SNMPv2c)
        4, 8, 116, 121, 83, 48, 110, 52, 51, 100, // OCTET STRING (Community = "tyS0n43d")
        160, 42, // GetRequest PDU (Tag = 0xA0), length 28
        2, 4, 74, 155, 107, 163, // INTEGER (Request ID = 1_251_699_619)
        2, 1, 0, // INTEGER (Error Status = 0)
        2, 1, 0, // INTEGER (Error Index = 0)
        48, 28, // SEQUENCE (VarBindList), length 22
        // First VarBind
        48, 12, // SEQUENCE, length 12
        6, 8, 43, 6, 1, 2, 1, 1, 1, 0, // OBJECT IDENTIFIER (1.3.6.1.2.1.1.1.0)
        5, 0, // NULL
        // Second VarBind
        48, 12, // SEQUENCE, length 12
        6, 8, 43, 6, 1, 2, 1, 1, 2, 0, // OBJECT IDENTIFIER (1.3.6.1.2.1.1.2.0)
        5, 0, // NULL
    ];

    assert_eq!(&pdu[..], &expected[..]);
}

#[test]
fn build_getnext_pdu() {
    let mut pdu = pdu::Buf::default();
    pdu::build_getnext(
        Version::V2C,
        b"tyS0n43d",
        1_251_699_618,
        &Oid::from(&[1, 3, 6, 1, 2, 1, 1, 1, 0]).unwrap(),
        &mut pdu,
        #[cfg(feature = "v3")]
        None,
    )
    .unwrap();

    let expected = &[
        0x30, 0x2b, 0x02, 0x01, 0x01, 0x04, 0x08, 0x74, 0x79, 0x53, 0x30, 0x6e, 0x34, 0x33, 0x64,
        0xa1, 0x1c, 0x02, 0x04, 0x4a, 0x9b, 0x6b, 0xa2, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00, 0x30,
        0x0e, 0x30, 0x0c, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00, 0x05, 0x00,
    ];

    println!("{:?}", pdu);
    println!("{:?}", &expected[..]);

    assert_eq!(&pdu[..], &expected[..]);
}

#[test]
fn build_getbulk_pdu() {
    let mut pdu = pdu::Buf::default();
    pdu::build_getbulk(
        Version::V2C,
        b"tyS0n43d",
        1_251_699_618,
        &[&Oid::from(&[1, 3, 6, 1, 2, 1, 1, 1, 0]).unwrap()],
        5,
        10,
        &mut pdu,
        #[cfg(feature = "v3")]
        None,
    )
    .unwrap();

    let expected = &[
        48, 43, 2, 1, 1, 4, 8, 116, 121, 83, 48, 110, 52, 51, 100, 165, 28, 2, 4, 74, 155, 107,
        162, 2, 1, 5, 2, 1, 10, 48, 14, 48, 12, 6, 8, 43, 6, 1, 2, 1, 1, 1, 0, 5, 0,
    ];

    assert_eq!(&pdu[..], &expected[..]);
}

#[test]
fn build_reply_pdu() {
    let mut buf = pdu::Buf::default();
    pdu::build(
        Version::V2C,
        b"tyS0n43d",
        snmp::MSG_RESPONSE,
        1_251_699_618,
        &[(
            &Oid::from(&[1, 3, 6, 1, 2, 1, 1, 1, 0]).unwrap(),
            Value::Null,
        )],
        8,
        1,
        &mut buf,
        #[cfg(feature = "v3")]
        None,
    )
    .unwrap();
    let pdu = Pdu::from_bytes(&buf).unwrap();
    assert_eq!(pdu.message_type, MessageType::Response);
    assert_eq!(pdu.error_status, 8);
    assert_eq!(pdu.error_index, 1);
}

#[test]
fn asn_read_byte() {
    let bytes = [1, 2, 3, 4];
    let mut reader = AsnReader::from_bytes(&bytes[..]);
    let a = reader.read_byte().unwrap();
    let b = reader.read_byte().unwrap();
    let c = reader.read_byte().unwrap();
    let d = reader.read_byte().unwrap();
    assert_eq!(&[a, b, c, d], &bytes[..]);
    assert_eq!(reader.read_byte(), Err(Error::AsnEof));
}

#[test]
fn asn_parse_getnext_pdu() {
    let pdu = &[
        0x30, 0x2b, 0x02, 0x01, 0x01, 0x04, 0x08, 0x74, 0x79, 0x53, 0x30, 0x6e, 0x34, 0x33, 0x64,
        0xa1, 0x1c, 0x02, 0x04, 0x4a, 0x9b, 0x6b, 0xa2, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00, 0x30,
        0x0e, 0x30, 0x0c, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00, 0x05, 0x00,
    ];
    let mut reader = AsnReader::from_bytes(&pdu[..]);
    reader
        .read_asn_sequence(|rdr| {
            let version = rdr.read_asn_integer()?;
            assert_eq!(version, Version::V2C as i64);
            let community = rdr.read_asn_octetstring()?;
            assert_eq!(community, b"tyS0n43d");
            println!("version: {}", version);
            let msg_ident = rdr.peek_byte()?;
            println!("msg_ident: {}", msg_ident);
            assert_eq!(msg_ident, snmp::MSG_GET_NEXT);
            rdr.read_constructed(msg_ident, |rdr| {
                let req_id = rdr.read_asn_integer()?;
                let error_status = rdr.read_asn_integer()?;
                let error_index = rdr.read_asn_integer()?;
                println!(
                    "req_id: {}, error_status: {}, error_index: {}",
                    req_id, error_status, error_index
                );
                assert_eq!(req_id, 1_251_699_618);
                assert_eq!(error_status, 0);
                assert_eq!(error_index, 0);
                rdr.read_asn_sequence(|rdr| {
                    rdr.read_asn_sequence(|rdr| {
                        let name = rdr.read_asn_objectidentifier()?;
                        let expected = Oid::from(&[1, 3, 6, 1, 2, 1, 1, 1, 0]).unwrap();
                        println!("name: {}", name);
                        assert_eq!(name, expected);
                        rdr.read_asn_null()
                    })
                })
            })
        })
        .unwrap();
}

#[test]
#[cfg(feature = "mibs")]
fn test_mib() {
    use crate::mibs::MibConversion as _;

    super::mibs::init(&super::mibs::Config::new().mibs(&["./ibmConvergedPowerSystems.mib"]))
        .unwrap();
    let snmp_oid = Oid::from(&[1, 3, 6, 1, 4, 1, 2, 6, 201, 3]).unwrap();
    let name = snmp_oid.mib_name().unwrap();
    assert_eq!(name, "IBM-CPS-MIB::cpsSystemSendTrap");
    let snmp_oid2 = Oid::from_mib_name(&name).unwrap();
    assert_eq!(snmp_oid, snmp_oid2);
}

#[test]
fn test_varbinds_no_such_object_no_such_instance_end_of_mib_view() {
    const EXPECTED_LEN: usize = 5;
    let raw: &[u8] = &[
        // VarBind 1
        0x30, 0x14, // SEQUENCE, length 20
        0x06, 0x0b, // OBJECT IDENTIFIER, length 11
        0x2b, 0x06, 0x01, 0x02, 0x01, 0x1f, 0x01, 0x01, 0x01, 0x06,
        0x02, // OID: 1.3.6.1.2.1.31.1.1.1.6.2
        0x46, 0x05, // Counter64, length 5
        0x01, 0x79, 0x66, 0xac, 0x06, // Value 6331739142
        // VarBind 2
        0x30, 0x0b, // SEQUENCE, length 11
        0x06, 0x07, // OBJECT IDENTIFIER, length 7
        0x2b, 0x06, 0x01, 0x02, 0x01, 0x87, 0x67, // OID: 1.3.6.1.2.1.999
        0x80, 0x00, // Context-specific tag (noSuchObject)
        // VarBind 3
        0x30, 0x0b, // SEQUENCE, length 11
        0x06, 0x07, // OBJECT IDENTIFIER, length 7
        0x2b, 0x06, 0x01, 0x02, 0x01, 0x87, 0x66, // OID: 1.3.6.1.2.1.998
        0x81, 0x00, // Context-specific tag (noSuchInstance)
        // VarBind 4
        0x30, 0x0b, // SEQUENCE, length 11
        0x06, 0x07, // OBJECT IDENTIFIER, length 7
        0x2b, 0x06, 0x01, 0x02, 0x01, 0x87, 0x65, // OID: 1.3.6.1.2.1.997
        0x82, 0x00, // Context-specific tag (endOfMibView)
        // VarBind 5
        0x30, 0x0f, // SEQUENCE, length 15
        0x06, 0x0a, // OBJECT IDENTIFIER, length 10
        0x2b, 0x06, 0x01, 0x02, 0x01, 0x02, 0x02, 0x01, 0x14,
        0x02, // OID: 1.3.6.1.2.1.2.2.1.20.2
        0x41, 0x01, 0x03, // (Counter32), value: 3
    ];
    let mut varbinds = Varbinds::from_bytes(raw);

    let count = varbinds.clone().count();
    assert_eq!(count, EXPECTED_LEN);

    let vec_varbinds: Vec<_> = varbinds.clone().collect();
    assert_eq!(vec_varbinds.len(), EXPECTED_LEN);

    let pair = varbinds.next();
    let (oid, val) = pair.unwrap();
    assert_eq!(oid, oid!(1.3.6 .1 .2 .1 .31 .1 .1 .1 .6 .2));
    assert!(matches!(val, Value::Counter64(6_331_739_142)));

    let pair = varbinds.next();
    let (oid, val) = pair.unwrap();
    assert_eq!(oid, oid!(1.3.6 .1 .2 .1 .999));
    assert!(matches!(val, Value::NoSuchObject));

    let pair = varbinds.next();
    let (oid, val) = pair.unwrap();
    assert_eq!(oid, oid!(1.3.6 .1 .2 .1 .998));
    assert!(matches!(val, Value::NoSuchInstance));

    let pair = varbinds.next();
    let (oid, val) = pair.unwrap();
    assert_eq!(oid, oid!(1.3.6 .1 .2 .1 .997));
    assert!(matches!(val, Value::EndOfMibView));

    let pair = varbinds.next();
    let (oid, val) = pair.unwrap();
    assert_eq!(oid, oid!(1.3.6 .1 .2 .1 .2 .2 .1 .20 .2));
    assert!(matches!(val, Value::Counter32(3)));
}

#[test]
fn test_pdu_to_bytes() {
    // Build a PDU using the build functions
    let mut buf = pdu::Buf::default();
    pdu::build_get(
        Version::V2C,
        b"public",
        12345,
        &Oid::from(&[1, 3, 6, 1, 2, 1, 1, 1, 0]).unwrap(),
        &mut buf,
        #[cfg(feature = "v3")]
        None,
    )
    .unwrap();

    // Parse the PDU from bytes
    let parsed_pdu = Pdu::from_bytes(&buf).unwrap();

    // Convert the parsed PDU back to bytes
    let converted_bytes = parsed_pdu.to_bytes().unwrap();

    // The converted bytes should match the original buffer
    assert_eq!(&buf[..], &converted_bytes[..]);

    // Verify we can parse the converted bytes again
    let reparsed_pdu = Pdu::from_bytes(&converted_bytes).unwrap();
    assert_eq!(reparsed_pdu.version, parsed_pdu.version);
    assert_eq!(reparsed_pdu.community, parsed_pdu.community);
    assert_eq!(reparsed_pdu.message_type, parsed_pdu.message_type);
    assert_eq!(reparsed_pdu.req_id, parsed_pdu.req_id);
}

#[test]
fn test_pdu_to_bytes_response() {
    // Build a response PDU
    let mut buf = pdu::Buf::default();
    pdu::build(
        Version::V2C,
        b"public",
        snmp::MSG_RESPONSE,
        99999,
        &[(
            &Oid::from(&[1, 3, 6, 1, 2, 1, 1, 1, 0]).unwrap(),
            Value::OctetString(b"Test System"),
        )],
        0, // error_status
        0, // error_index
        &mut buf,
        #[cfg(feature = "v3")]
        None,
    )
    .unwrap();

    // Parse and convert back
    let pdu = Pdu::from_bytes(&buf).unwrap();
    let bytes = pdu.to_bytes().unwrap();

    // Verify the bytes can be used for UDP communication
    assert!(!bytes.is_empty());
    assert_eq!(&buf[..], &bytes[..]);

    // Test as_bytes method as well
    let bytes2 = pdu.as_bytes().unwrap();
    assert_eq!(bytes, bytes2);
}

#[test]
#[cfg(feature = "v3")]
fn test_v3_pdu_to_bytes() {
    use crate::v3;

    let mut buf = pdu::Buf::default();
    let security = v3::Security::new(b"public", b"secure")
        .with_auth_protocol(v3::AuthProtocol::Sha1)
        .with_auth(v3::Auth::AuthPriv {
            cipher: v3::Cipher::Aes128,
            privacy_password: b"privacy_password".to_vec(),
        })
        .with_engine_id(&[0x80, 0x00, 0x00, 0x00, 0x01])
        .unwrap()
        .with_engine_boots_and_time(1, 100);

    // Build a V3 PDU
    pdu::build_get(
        Version::V3,
        b"",
        12345,
        &Oid::from(&[1, 3, 6, 1, 2, 1, 1, 1, 0]).unwrap(),
        &mut buf,
        Some(&security),
    )
    .unwrap();

    println!("Original bytes: {:?}", &buf[..]);

    // Parse it to get a Pdu struct
    let mut security_parse = security.clone();
    let pdu = Pdu::from_bytes_with_security(&buf, Some(&mut security_parse)).unwrap();

    println!("Parsed PDU: {:?}", pdu);

    assert_eq!(pdu.version().unwrap(), Version::V3);

    // Convert back to bytes using the new method
    let bytes = pdu.to_bytes_with_security(Some(&security)).unwrap();

    println!("Re-encoded bytes: {:?}", bytes);

    assert!(!bytes.is_empty());

    // Verify we can parse the result again
    let mut security_reparse = security.clone();
    let pdu2 = Pdu::from_bytes_with_security(&bytes, Some(&mut security_reparse)).unwrap();

    assert_eq!(pdu2.req_id, 12345);
    assert_eq!(pdu2.version().unwrap(), Version::V3);
}
