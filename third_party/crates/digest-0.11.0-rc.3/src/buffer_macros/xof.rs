/// Creates a buffered wrapper around block-level "core" type which implements extendable output size traits.
#[macro_export]
macro_rules! buffer_xof {
    (
        $(#[$hasher_attr:meta])*
        $hasher_vis:vis struct $hasher_name:ident($hasher_core:ty);
        $(oid: $oid:literal;)?
        impl: $($hasher_trait_name:ident)*;

        $(#[$reader_attr:meta])*
        $reader_vis:vis struct $reader_name:ident($reader_core:ty);
        impl: $($reader_trait_name:ident)*;
    ) => {
        $(#[$hasher_attr])*
        $hasher_vis struct $hasher_name {
            core: $hasher_core,
            buffer: $crate::block_api::Buffer<$hasher_core>,
        }

        impl $crate::ExtendableOutput for $hasher_name {
            type Reader = $reader_name;

            #[inline]
            fn finalize_xof(mut self) -> Self::Reader {
                let Self { core, buffer } = &mut self;
                let core = <$hasher_core as $crate::block_api::ExtendableOutputCore>::finalize_xof_core(core, buffer);
                let buffer = Default::default();
                Self::Reader { core, buffer }
            }
        }

        $(
            #[cfg(feature = "oid")]
            impl $crate::const_oid::AssociatedOid for $hasher_name {
                const OID: $crate::const_oid::ObjectIdentifier =
                    $crate::const_oid::ObjectIdentifier::new_unwrap($oid);
            }
        )?

        $crate::buffer_xof!(
            impl_inner: $hasher_name($hasher_core);
            $($hasher_trait_name)*;
        );

        $(#[$reader_attr])*
        $reader_vis struct $reader_name {
            core: $reader_core,
            buffer: $crate::block_buffer::ReadBuffer<<$reader_core as $crate::block_api::BlockSizeUser>::BlockSize>,
        }

        impl $crate::XofReader for $reader_name {
            #[inline]
            fn read(&mut self, buf: &mut [u8]) {
                let Self { core, buffer } = self;
                buffer.read(buf, |block| {
                    *block = $crate::block_api::XofReaderCore::read_block(core);
                });
            }
        }

        $crate::buffer_xof!(
            impl_inner: $reader_name($reader_core);
            $($reader_trait_name)*;
        );
    };

    // Terminates `impl_inner` sequences.
    (
        impl_inner: $name:ident($core_ty:ty); ;
    ) => {};

    // Implements the set of traits common for XOF hashers
    (
        impl_inner: $name:ident($core_ty:ty);
        XofHasherTraits $($trait_name:ident)*;
    ) => {
        $crate::buffer_xof!(
            impl_inner: $name($core_ty);
            Debug AlgorithmName Clone Default BlockSizeUser CoreProxy HashMarker Update SerializableState Reset ExtendableOutputReset $($trait_name)* ;
        );
    };

    // Implements the set of traits common for XOF readers
    (
        impl_inner: $name:ident($core_ty:ty);
        XofReaderTraits $($trait_name:ident)*;
    ) => {
        $crate::buffer_xof!(
            impl_inner: $name($core_ty);
            Debug Clone BlockSizeUser
            $($trait_name)*;);
    };

    // Implements `Debug`
    (
        impl_inner: $name:ident($core_ty:ty);
        Debug $($trait_name:ident)*;
    ) => {
        impl core::fmt::Debug for $name {
            #[inline]
            fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                f.write_str(concat!(stringify!($name), " { ... }"))
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `AlgorithmName`
    (
        impl_inner: $name:ident($core_ty:ty);
        AlgorithmName $($trait_name:ident)*;
    ) => {
        impl $crate::crypto_common::AlgorithmName for $name {
            #[inline]
            fn write_alg_name(f: &mut core::fmt::Formatter<'_>) -> Result<(), core::fmt::Error> {
                <$core_ty as $crate::crypto_common::AlgorithmName>::write_alg_name(f)
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `Default`
    (
        impl_inner: $name:ident($core_ty:ty);
        Default $($trait_name:ident)*;
    ) => {
        impl Default for $name {
            #[inline]
            fn default() -> Self {
                Self {
                    core: Default::default(),
                    buffer: Default::default(),
                }
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `CustomizedInit`
    (
        impl_inner: $name:ident($core_ty:ty);
        CustomizedInit $($trait_name:ident)*;
    ) => {
        impl $crate::CustomizedInit for $name {
            #[inline]
            fn new_customized(customization: &[u8]) -> Self {
                Self {
                    core: $crate::CustomizedInit::new_customized(customization),
                    buffer: Default::default(),
                }
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `Clone`
    (
        impl_inner: $name:ident($core_ty:ty);
        Clone $($trait_name:ident)*;
    ) => {
        impl Clone for $name {
            #[inline]
            fn clone(&self) -> Self {
                Self {
                    core: Clone::clone(&self.core),
                    buffer: Clone::clone(&self.buffer),
                }
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `BlockSizeUser`
    (
        impl_inner: $name:ident($core_ty:ty);
        BlockSizeUser $($trait_name:ident)*;
    ) => {
        impl $crate::block_api::BlockSizeUser for $name {
            type BlockSize = <$core_ty as $crate::crypto_common::BlockSizeUser>::BlockSize;
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `CoreProxy`
    (
        impl_inner: $name:ident($core_ty:ty);
        CoreProxy $($trait_name:ident)*;
    ) => {
        impl $crate::block_api::CoreProxy for $name {
            type Core = $core_ty;
            fn compose(core: Self::Core, buffer: $crate::block_api::Buffer<Self::Core>) -> Self {
                Self { core, buffer }
            }
            fn decompose(self) -> (Self::Core, $crate::block_api::Buffer<Self::Core>) {
                let Self { core, buffer } = self;
                (core, buffer)
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `HashMarker`
    (
        impl_inner: $name:ident($core_ty:ty);
        HashMarker $($trait_name:ident)*;
    ) => {
        impl $crate::HashMarker for $name {}

        // Verify that `$core_ty` implements `HashMarker`
        const _: () = {
            fn check(v: &$core_ty) {
                v as &dyn $crate::HashMarker;
            }
        };

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `Update`
    (
        impl_inner: $name:ident($core_ty:ty);
        Update $($trait_name:ident)*;
    ) => {
        impl $crate::Update for $name {
            #[inline]
            fn update(&mut self, data: &[u8]) {
                let Self { core, buffer } = self;
                buffer.digest_blocks(data, |blocks| {
                    $crate::block_api::UpdateCore::update_blocks(core, blocks)
                });
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `Reset`
    (
        impl_inner: $name:ident($core_ty:ty);
        Reset $($trait_name:ident)*;
    ) => {
        impl $crate::Reset for $name {
            #[inline]
            fn reset(&mut self) {
                $crate::Reset::reset(&mut self.core);
                self.buffer.reset();
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `ExtendableOutputReset`
    (
        impl_inner: $name:ident($core_ty:ty);
        ExtendableOutputReset $($trait_name:ident)*;
    ) => {
        impl $crate::ExtendableOutputReset for $name {
            #[inline]
            fn finalize_xof_reset(&mut self) -> Self::Reader {
                let Self { core, buffer } = self;
                let core = <$core_ty as $crate::block_api::ExtendableOutputCore>::finalize_xof_core(core, buffer);
                $crate::Reset::reset(self);
                let buffer = Default::default();
                Self::Reader { core, buffer }
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };

    // Implements `SerializableState`
    (
        impl_inner: $name:ident($core_ty:ty);
        SerializableState $($trait_name:ident)*;
    ) => {
        impl $crate::crypto_common::hazmat::SerializableState for $name {
            type SerializedStateSize = $crate::typenum::Sum<
                <$core_ty as $crate::crypto_common::hazmat::SerializableState>::SerializedStateSize,
                $crate::block_buffer::SerializedBufferSize<
                    <$core_ty as $crate::block_api::BlockSizeUser>::BlockSize,
                    <$core_ty as $crate::block_api::BufferKindUser>::BufferKind,
                >
            >;

            #[inline]
            fn serialize(&self) -> $crate::crypto_common::hazmat::SerializedState<Self> {
                let serialized_core = self.core.serialize();
                let serialized_buf = self.buffer.serialize();
                serialized_core.concat(serialized_buf)
            }

            #[inline]
            fn deserialize(
                serialized_state: &$crate::crypto_common::hazmat::SerializedState<Self>,
            ) -> Result<Self, $crate::crypto_common::hazmat::DeserializeStateError> {
                use $crate::crypto_common::hazmat::{SerializableState, DeserializeStateError};

                let (serialized_core, serialized_buf) = serialized_state
                    .split_ref::<<$core_ty as SerializableState>::SerializedStateSize>();

                let core = SerializableState::deserialize(serialized_core)?;
                let buffer = $crate::block_buffer::BlockBuffer::deserialize(serialized_buf)
                    .map_err(|_| DeserializeStateError)?;

                Ok(Self { core, buffer })
            }
        }

        $crate::buffer_xof!(impl_inner: $name($core_ty); $($trait_name)*;);
    };
}
