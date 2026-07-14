use crate::{FixedOutputReset, Mac, crypto_common::KeyInit};

/// Tag truncation side used in MAC tests
#[derive(Clone, Copy, Debug)]
pub enum MacTruncSide {
    /// Tag truncated from left (i.e. `tag[..n]`)
    Left,
    /// Tag truncated from right (i.e. `tag[n..]`)
    Right,
    /// Tag is not truncated
    None,
}

/// MAC test vector
#[derive(Debug, Clone, Copy)]
pub struct MacTestVector {
    /// Initialization key
    pub key: &'static [u8],
    /// Input message
    pub input: &'static [u8],
    /// Output tag
    pub tag: &'static [u8],
}

/// Run MAC test
pub fn mac_test<M: Mac + KeyInit + Clone>(
    &MacTestVector { key, input, tag }: &MacTestVector,
    trunc_side: MacTruncSide,
) -> Result<(), &'static str> {
    let Ok(mac0) = <M as KeyInit>::new_from_slice(key) else {
        return Err("Failed to initialize MAC instance");
    };

    let mut mac = mac0.clone();
    mac.update(input);
    let result = mac.finalize().into_bytes();
    let n = tag.len();
    let result_bytes = match trunc_side {
        MacTruncSide::Left => &result[..n],
        MacTruncSide::Right => &result[result.len() - n..],
        MacTruncSide::None => &result[..],
    };
    if result_bytes != tag {
        return Err("whole message");
    }

    // test reading different chunk sizes
    for chunk_size in 1..core::cmp::min(64, input.len()) {
        let mut mac = mac0.clone();
        for chunk in input.chunks(chunk_size) {
            mac.update(chunk);
        }
        let res = match trunc_side {
            MacTruncSide::Left => mac.verify_truncated_left(tag),
            MacTruncSide::Right => mac.verify_truncated_right(tag),
            MacTruncSide::None => mac.verify_slice(tag),
        };
        if res.is_err() {
            return Err("chunked message");
        }
    }

    Ok(())
}

/// Run resettable MAC test
pub fn reset_mac_test<M: Mac + KeyInit + FixedOutputReset + Clone>(
    &MacTestVector { key, input, tag }: &MacTestVector,
    trunc_side: MacTruncSide,
) -> Result<(), &'static str> {
    let Ok(mac0) = <M as KeyInit>::new_from_slice(key) else {
        return Err("Failed to initialize MAC instance");
    };

    let mut mac = mac0.clone();
    Mac::update(&mut mac, input);
    let result = mac.finalize_reset().into_bytes();
    let n = tag.len();
    let result_bytes = match trunc_side {
        MacTruncSide::Left => &result[..n],
        MacTruncSide::Right => &result[result.len() - n..],
        MacTruncSide::None => &result[..],
    };
    if result_bytes != tag {
        return Err("whole message");
    }

    // test if reset worked correctly
    Mac::update(&mut mac, input);
    let res = match trunc_side {
        MacTruncSide::Left => mac.verify_truncated_left(tag),
        MacTruncSide::Right => mac.verify_truncated_right(tag),
        MacTruncSide::None => mac.verify_slice(tag),
    };
    if res.is_err() {
        return Err("after reset");
    }

    // test reading different chunk sizes
    for chunk_size in 1..core::cmp::min(64, input.len()) {
        let mut mac = mac0.clone();
        for chunk in input.chunks(chunk_size) {
            Mac::update(&mut mac, chunk);
        }
        let res = match trunc_side {
            MacTruncSide::Left => mac.verify_truncated_left(tag),
            MacTruncSide::Right => mac.verify_truncated_right(tag),
            MacTruncSide::None => mac.verify_slice(tag),
        };
        if res.is_err() {
            return Err("chunked message");
        }
    }

    Ok(())
}

/// Define MAC test
#[macro_export]
macro_rules! new_mac_test {
    ($name:ident, $mac:ty, $test_fn:ident $(,)?) => {
        digest::new_mac_test!($name, $mac, $test_fn, $crate::dev::MacTruncSide::None);
    };
    ($name:ident, $mac:ty, $test_fn:ident, trunc_left $(,)?) => {
        digest::new_mac_test!($name, $mac, $test_fn, $crate::dev::MacTruncSide::Left);
    };
    ($name:ident, $mac:ty, $test_fn:ident, trunc_right $(,)?) => {
        digest::new_mac_test!($name, $mac, $test_fn, $crate::dev::MacTruncSide::Right);
    };
    ($name:ident, $mac:ty, $test_fn:ident, $trunc:expr $(,)?) => {
        #[test]
        fn $name() {
            use digest::dev::MacTestVector;

            $crate::dev::blobby::parse_into_structs!(
                include_bytes!(concat!("data/", stringify!($name), ".blb"));
                static TEST_VECTORS: &[MacTestVector { key, input, tag }];
            );

            for (i, tv) in TEST_VECTORS.iter().enumerate() {
                if let Err(reason) = $test_fn::<$mac>(tv, $trunc) {
                    panic!(
                        "\n\
                        Failed test #{i}\n\
                        reason:\t{reason:?}\n\
                        test vector:\t{tv:?}\n"
                    );
                }
            }
        }
    };
}
