use hex_literal::hex;
use polyval::{
    BLOCK_SIZE, Polyval, PolyvalGeneric,
    universal_hash::{KeyInit, Reset, UniversalHash, crypto_common::KeySizeUser, typenum::U16},
};

//
// Test vectors for POLYVAL from RFC 8452 Appendix A
// <https://tools.ietf.org/html/rfc8452#appendix-A>
//

const H: [u8; BLOCK_SIZE] = hex!("25629347589242761d31f826ba4b757b");
const X_1: [u8; BLOCK_SIZE] = hex!("4f4f95668c83dfb6401762bb2d01a262");
const X_2: [u8; BLOCK_SIZE] = hex!("d1a24ddd2721d006bbe45f20d3c9f362");

/// POLYVAL(H, X_1, X_2)
const POLYVAL_RESULT: [u8; BLOCK_SIZE] = hex!("f7a3b47b846119fae5b7866cf5e5b77e");

#[test]
fn polyval_test_vector() {
    let mut poly = Polyval::new(&H.into());
    poly.update(&[X_1.into(), X_2.into()]);

    let result = poly.finalize();
    assert_eq!(&POLYVAL_RESULT[..], result.as_slice());
}

// A longer test case, to ensure that long-input optimizations
// behave correctly.

fn longer_test<Imp>()
where
    Imp: UniversalHash + KeyInit + Reset + Clone + KeySizeUser<KeySize = U16>,
{
    let inp = (1..=4096).map(|n| (n * 47) as u8).collect::<Vec<_>>();

    // Try computing polyval all at once.
    let mut poly = Imp::new(&H.into());
    poly.update_padded(&inp);
    let result1 = poly.finalize_reset();

    // Try computing polyval one block at a time.
    for block in inp.chunks(BLOCK_SIZE) {
        poly.update(&[block.try_into().unwrap()]);
    }
    let result2 = poly.finalize();

    // Make sure the results are the same.
    assert_eq!(result1, result2);
}

#[test]
fn longer_test_x1() {
    longer_test::<PolyvalGeneric<1>>();
}
#[test]
fn longer_test_x2() {
    longer_test::<PolyvalGeneric<2>>();
}
#[test]
fn longer_test_x4() {
    longer_test::<PolyvalGeneric<4>>();
}
#[test]
fn longer_test_x8() {
    longer_test::<PolyvalGeneric<8>>();
}
