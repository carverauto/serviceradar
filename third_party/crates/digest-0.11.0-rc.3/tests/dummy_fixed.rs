#![cfg(feature = "block-api")]

mod block_api {
    use core::fmt;
    use digest::{
        HashMarker, Output, OutputSizeUser, Reset,
        block_api::{
            AlgorithmName, Block, BlockSizeUser, Buffer, BufferKindUser, FixedOutputCore,
            UpdateCore,
        },
        consts::U8,
        crypto_common::hazmat::{DeserializeStateError, SerializableState, SerializedState},
    };

    /// Core of primitive XOR hasher for testing purposes
    #[derive(Clone, Default, Debug)]
    pub struct FixedHashCore {
        state: u64,
    }

    impl AlgorithmName for FixedHashCore {
        fn write_alg_name(f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
            f.write_str("FixedHash")
        }
    }

    impl BlockSizeUser for FixedHashCore {
        type BlockSize = U8;
    }

    impl BufferKindUser for FixedHashCore {
        type BufferKind = block_buffer::Eager;
    }

    impl Reset for FixedHashCore {
        fn reset(&mut self) {
            self.state = 0;
        }
    }

    impl UpdateCore for FixedHashCore {
        fn update_blocks(&mut self, blocks: &[Block<Self>]) {
            for block in blocks {
                self.state ^= u64::from_le_bytes(block.0)
            }
        }
    }

    impl HashMarker for FixedHashCore {}

    impl OutputSizeUser for FixedHashCore {
        type OutputSize = U8;
    }

    impl FixedOutputCore for FixedHashCore {
        fn finalize_fixed_core(&mut self, buffer: &mut Buffer<Self>, out: &mut Output<Self>) {
            let block = buffer.pad_with_zeros();
            self.state ^= u64::from_le_bytes(block.0);
            out.copy_from_slice(&self.state.to_le_bytes());
        }
    }

    impl SerializableState for FixedHashCore {
        type SerializedStateSize = U8;

        fn serialize(&self) -> SerializedState<Self> {
            self.state.to_le_bytes().into()
        }

        fn deserialize(
            serialized_state: &SerializedState<Self>,
        ) -> Result<Self, DeserializeStateError> {
            Ok(Self {
                state: u64::from_le_bytes(serialized_state.0),
            })
        }
    }

    #[cfg(feature = "zeroize")]
    impl Drop for FixedHashCore {
        fn drop(&mut self) {
            use zeroize::Zeroize;
            self.state.zeroize();
        }
    }

    #[cfg(feature = "zeroize")]
    impl zeroize::ZeroizeOnDrop for FixedHashCore {}
}

digest::buffer_fixed!(
    /// Primitive XOR hasher for testing purposes
    pub struct FixedHash(block_api::FixedHashCore);
    impl: BaseFixedTraits Default Clone HashMarker Reset FixedOutputReset;
);
digest::buffer_fixed!(
    /// Primitive XOR hasher for testing purposes
    pub struct FixedHashWithSer(block_api::FixedHashCore);
    impl: FixedHashTraits;
);
digest::buffer_fixed!(
    /// Primitive XOR hasher for testing purposes
    pub struct FixedHashWithOid(block_api::FixedHashCore);
    oid: "0.1.2.3.4.5";
    impl: BaseFixedTraits Default Clone HashMarker Reset FixedOutputReset;
);
digest::buffer_fixed!(
    /// Primitive XOR hasher for testing purposes
    pub struct FixedHashWithOidSer(block_api::FixedHashCore);
    oid: "0.1.2.3.4.5";
    impl: FixedHashTraits;
);

#[cfg(feature = "dev")]
digest::hash_serialization_test!(fixed_hash_serialization, FixedHashWithSer,);

#[cfg(feature = "zeroize")]
/// check for `ZeroizeOnDrop` implementations
const _: () = {
    const fn check_zeroize<T: zeroize::ZeroizeOnDrop>() {}
    check_zeroize::<FixedHashWithSer>();
    check_zeroize::<FixedHashWithOidSer>();
};
