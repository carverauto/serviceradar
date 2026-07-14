use tls_codec::{DeserializeBytes, TlsByteVecU16, TlsByteVecU24, TlsByteVecU32, TlsByteVecU8};

#[test]
fn deserialize_tls_byte_vec_u8() {
    let bytes = [3, 2, 1, 0];
    let (result, rest) = TlsByteVecU8::tls_deserialize_bytes(&bytes).unwrap();
    let expected_result = [2, 1, 0];
    assert_eq!(result.as_slice(), expected_result);
    assert_eq!(rest, []);
}

#[test]
fn deserialize_tls_byte_vec_u16() {
    let bytes = [0, 3, 2, 1, 0];
    let (result, rest) = TlsByteVecU16::tls_deserialize_bytes(&bytes).unwrap();
    let expected_result = [2, 1, 0];
    assert_eq!(result.as_slice(), expected_result);
    assert_eq!(rest, []);
}

#[test]
fn deserialize_tls_byte_vec_u24() {
    let bytes = [0, 0, 3, 2, 1, 0];
    let (result, rest) = TlsByteVecU24::tls_deserialize_bytes(&bytes).unwrap();
    let expected_result = [2, 1, 0];
    assert_eq!(result.as_slice(), expected_result);
    assert_eq!(rest, []);
}

#[test]
fn deserialize_tls_byte_vec_u32() {
    let bytes = [0, 0, 0, 3, 2, 1, 0];
    let (result, rest) = TlsByteVecU32::tls_deserialize_bytes(&bytes).unwrap();
    let expected_result = [2, 1, 0];
    assert_eq!(result.as_slice(), expected_result);
    assert_eq!(rest, []);
}
