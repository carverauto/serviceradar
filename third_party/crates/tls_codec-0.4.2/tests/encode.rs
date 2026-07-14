#![cfg(feature = "std")]

use tls_codec::{Serialize, TlsVecU16, TlsVecU24, VLByteSlice, VLBytes, U24};

#[test]
fn serialize_primitives() {
    let mut v = Vec::new();
    77u8.tls_serialize(&mut v).expect("Error encoding u8");
    88u8.tls_serialize(&mut v).expect("Error encoding u8");
    355u16.tls_serialize(&mut v).expect("Error encoding u16");
    U24::try_from(65609usize)
        .unwrap()
        .tls_serialize(&mut v)
        .expect("Error encoding U24");
    let b = [77u8, 88, 1, 99, 1, 0, 73];
    assert_eq!(&b[..], &v[..]);
}

#[test]
fn serialize_tls_vec() {
    let mut v = Vec::new();
    1u8.tls_serialize(&mut v).expect("Error encoding u8");
    TlsVecU16::<u8>::from_slice(&[77, 88, 1, 99])
        .tls_serialize(&mut v)
        .expect("Error encoding u8");
    TlsVecU24::<u8>::from_slice(&[255, 42, 73])
        .tls_serialize(&mut v)
        .expect("Error encoding u8");

    let b = [1u8, 0, 4, 77, 88, 1, 99, 0, 0, 3, 255, 42, 73];
    assert_eq!(&b[..], &v[..]);
}

#[test]
fn serialize_var_len_vec() {
    let v = vec![9u8, 2, 98, 34, 55, 90, 54];
    let serialized = v.tls_serialize_detached().expect("Error encoding vector");
    assert_eq!(serialized, vec![7, 9, 2, 98, 34, 55, 90, 54]);

    let serialized = Vec::<u8>::new()
        .tls_serialize_detached()
        .expect("Error encoding vector");
    assert_eq!(serialized, vec![0x00]);
}

#[test]
fn serialize_var_len_bytes() {
    let v = VLBytes::new(vec![9u8, 2, 98, 34, 55, 90, 54]);
    let serialized = v.tls_serialize_detached().expect("Error encoding vector");
    assert_eq!(serialized, vec![7, 9, 2, 98, 34, 55, 90, 54]);

    let serialized = VLBytes::new(vec![])
        .tls_serialize_detached()
        .expect("Error encoding vector");
    assert_eq!(serialized, vec![0x00]);

    let v = vec![9u8, 2, 98, 34, 55, 90, 54];
    let serialized = VLByteSlice(&v)
        .tls_serialize_detached()
        .expect("Error encoding vector");
    assert_eq!(serialized, vec![7, 9, 2, 98, 34, 55, 90, 54]);

    let serialized = VLByteSlice(&[])
        .tls_serialize_detached()
        .expect("Error encoding vector");
    assert_eq!(serialized, vec![0x00]);
}

#[test]
fn serialize_var_len_boundaries() {
    let v = VLBytes::new(vec![99u8; 63]);
    let serialized = v.tls_serialize_detached().expect("Error encoding vector");
    assert_eq!(&serialized[0..5], &[63, 99, 99, 99, 99]);

    let v = VLBytes::new(vec![99u8; 64]);
    let serialized = v.tls_serialize_detached().expect("Error encoding vector");
    assert_eq!(&serialized[0..5], &[0x40, 64, 99, 99, 99]);

    let v = VLBytes::new(vec![99u8; 16383]);
    let serialized = v.tls_serialize_detached().expect("Error encoding vector");
    assert_eq!(&serialized[0..5], &[0x7f, 0xff, 99, 99, 99]);

    let v = VLBytes::new(vec![99u8; 16384]);
    let serialized = v.tls_serialize_detached().expect("Error encoding vector");
    assert_eq!(&serialized[0..5], &[0x80, 0, 0x40, 0, 99]);
}
