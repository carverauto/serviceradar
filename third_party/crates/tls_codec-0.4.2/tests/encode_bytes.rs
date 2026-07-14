use tls_codec::{SerializeBytes, TlsByteVecU16, TlsByteVecU24, TlsByteVecU32, TlsByteVecU8, U24};

#[test]
fn serialize_primitives() {
    let mut v = Vec::new();
    v.append(&mut 77u8.tls_serialize().expect("Error encoding u8"));
    v.append(&mut 88u8.tls_serialize().expect("Error encoding u8"));
    v.append(&mut 355u16.tls_serialize().expect("Error encoding u16"));
    v.append(
        &mut U24::try_from(65609usize)
            .unwrap()
            .tls_serialize()
            .expect("Error encoding U24"),
    );
    let b = [77u8, 88, 1, 99, 1, 0, 73];
    assert_eq!(&b[..], &v[..]);
}

#[test]
fn serialize_var_len_vec() {
    let v = vec![9u8, 2, 98, 34, 55, 90, 54];
    let serialized = v.tls_serialize().expect("Error encoding vector");
    assert_eq!(serialized, vec![7, 9, 2, 98, 34, 55, 90, 54]);

    let serialized = Vec::<u8>::new()
        .tls_serialize()
        .expect("Error encoding vector");
    assert_eq!(serialized, vec![0x00]);
}

#[test]
fn serialize_var_len_boundaries() {
    let v = vec![99u8; 63];
    let serialized = v.tls_serialize().expect("Error encoding vector");
    assert_eq!(&serialized[0..5], &[63, 99, 99, 99, 99]);

    let v = vec![99u8; 64];
    let serialized = v.tls_serialize().expect("Error encoding vector");
    assert_eq!(&serialized[0..5], &[0x40, 64, 99, 99, 99]);

    let v = vec![99u8; 16383];
    let serialized = v.tls_serialize().expect("Error encoding vector");
    assert_eq!(&serialized[0..5], &[0x7f, 0xff, 99, 99, 99]);

    let v = vec![99u8; 16384];
    let serialized = v.tls_serialize().expect("Error encoding vector");
    assert_eq!(&serialized[0..5], &[0x80, 0, 0x40, 0, 99]);
}

#[test]
fn serialize_tls_byte_vec_u8() {
    let byte_vec = TlsByteVecU8::from_slice(&[1, 2, 3]);
    let actual_result = byte_vec
        .tls_serialize()
        .expect("Error encoding byte vector");
    assert_eq!(actual_result, vec![3, 1, 2, 3]);
}

#[test]
fn serialize_tls_byte_vec_u16() {
    let byte_vec = TlsByteVecU16::from_slice(&[1, 2, 3]);
    let actual_result = byte_vec
        .tls_serialize()
        .expect("Error encoding byte vector");
    assert_eq!(actual_result, vec![0, 3, 1, 2, 3]);
}

#[test]
fn serialize_tls_byte_vec_u24() {
    let byte_vec = TlsByteVecU24::from_slice(&[1, 2, 3]);
    let actual_result = byte_vec
        .tls_serialize()
        .expect("Error encoding byte vector");
    assert_eq!(actual_result, vec![0, 0, 3, 1, 2, 3]);
}

#[test]
fn serialize_tls_byte_vec_u32() {
    let byte_vec = TlsByteVecU32::from_slice(&[1, 2, 3]);
    let actual_result = byte_vec
        .tls_serialize()
        .expect("Error encoding byte vector");
    assert_eq!(actual_result, vec![0, 0, 0, 3, 1, 2, 3]);
}
