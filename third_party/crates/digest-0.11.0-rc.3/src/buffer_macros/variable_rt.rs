/// Creates a buffered wrapper around block-level "core" type which implements variable output size traits
/// with output size selected at run time.
#[macro_export]
macro_rules! buffer_rt_variable {
    (
        $(#[$attr:meta])*
        $vis:vis struct $name:ident($core_ty:ty);
        exclude: SerializableState;
    ) => {
        $(#[$attr])*
        $vis struct $name {
            core: $core_ty,
            buffer: $crate::block_api::Buffer<$core_ty>,
            output_size: u8,
        }

        impl core::fmt::Debug for $name {
            #[inline]
            fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                f.write_str(concat!(stringify!($name), " { ... }"))
            }
        }

        impl $crate::crypto_common::AlgorithmName for $name {
            #[inline]
            fn write_alg_name(f: &mut core::fmt::Formatter<'_>) -> Result<(), core::fmt::Error> {
                <$core_ty as $crate::crypto_common::AlgorithmName>::write_alg_name(f)
            }
        }

        impl Clone for $name {
            #[inline]
            fn clone(&self) -> Self {
                Self {
                    core: Clone::clone(&self.core),
                    buffer: Clone::clone(&self.buffer),
                    output_size: self.output_size,
                }
            }
        }

        impl $crate::Reset for $name {
            #[inline]
            fn reset(&mut self) {
                let size = self.output_size.into();
                self.core = <$core_ty as $crate::block_api::VariableOutputCore>::new(size).unwrap();
                self.buffer.reset();
            }
        }

        impl $crate::block_api::BlockSizeUser for $name {
            type BlockSize = <$core_ty as $crate::crypto_common::BlockSizeUser>::BlockSize;
        }

        impl $crate::HashMarker for $name {}

        // Verify that `$wrapped_ty` implements `HashMarker`
        const _: () = {
            fn check(v: &$core_ty) {
                v as &dyn $crate::HashMarker;
            }
        };

        impl $crate::Update for $name {
            #[inline]
            fn update(&mut self, data: &[u8]) {
                let Self { core, buffer, .. } = self;
                buffer.digest_blocks(data, |blocks| {
                    $crate::block_api::UpdateCore::update_blocks(core, blocks);
                });
            }
        }

        impl $name {
            #[inline]
            fn finalize_dirty(&mut self, out: &mut [u8]) -> Result<(), $crate::InvalidBufferSize> {
                let Self {
                    core,
                    buffer,
                    output_size,
                } = self;
                let size_u8 = u8::try_from(out.len()).map_err(|_| $crate::InvalidBufferSize)?;

                let max_size = <Self as $crate::VariableOutput>::MAX_OUTPUT_SIZE;
                if out.len() > max_size || size_u8 != *output_size {
                    return Err($crate::InvalidBufferSize);
                }
                let mut full_res = Default::default();
                $crate::block_api::VariableOutputCore::finalize_variable_core(core, buffer, &mut full_res);
                let n = out.len();
                let m = full_res.len() - n;
                use $crate::block_api::TruncSide::{Left, Right};
                let side = <$core_ty as $crate::block_api::VariableOutputCore>::TRUNC_SIDE;
                match side {
                    Left => out.copy_from_slice(&full_res[..n]),
                    Right => out.copy_from_slice(&full_res[m..]),
                }
                Ok(())
            }
        }

        impl $crate::VariableOutput for $name {
            const MAX_OUTPUT_SIZE: usize = <
                <$core_ty as $crate::block_api::OutputSizeUser>::OutputSize
                as $crate::typenum::Unsigned
            >::USIZE;

            #[inline]
            fn new(output_size: usize) -> Result<Self, $crate::InvalidOutputSize> {
                let output_size = u8::try_from(output_size).map_err(|_| $crate::InvalidOutputSize)?;
                let buffer = Default::default();
                let core = <$core_ty as $crate::block_api::VariableOutputCore>::new(output_size.into())?;
                Ok(Self {
                    core,
                    buffer,
                    output_size,
                })
            }

            #[inline]
            fn output_size(&self) -> usize {
                self.output_size.into()
            }

            #[inline]
            fn finalize_variable(mut self, out: &mut [u8]) -> Result<(), $crate::InvalidBufferSize> {
                self.finalize_dirty(out)
            }
        }

        impl $crate::VariableOutputReset for $name {
            #[inline]
            fn finalize_variable_reset(
                &mut self,
                out: &mut [u8],
            ) -> Result<(), $crate::InvalidBufferSize> {
                self.finalize_dirty(out)?;
                $crate::Reset::reset(self);
                Ok(())
            }
        }

        impl Drop for $name {
            #[inline]
            fn drop(&mut self) {
                #[cfg(feature = "zeroize")]
                {
                    use $crate::zeroize::Zeroize;
                    self.buffer.zeroize();
                    self.output_size.zeroize();
                }
            }
        }

        #[cfg(feature = "zeroize")]
        impl $crate::zeroize::ZeroizeOnDrop for $name {}
    };

    (
        $(#[$attr:meta])*
        $vis:vis struct $name:ident($core_ty:ty);
    ) => {
        $crate::buffer_rt_variable!(
            $(#[$attr])*
            $vis struct $name($core_ty);
            exclude: SerializableState;
        );

        impl $crate::crypto_common::hazmat::SerializableState for $name {
            type SerializedStateSize = $crate::typenum::Add1<$crate::typenum::Sum<
                <$core_ty as $crate::crypto_common::hazmat::SerializableState>::SerializedStateSize,
                <$core_ty as $crate::block_api::BlockSizeUser>::BlockSize,
            >>;

            #[inline]
            fn serialize(&self) -> $crate::crypto_common::hazmat::SerializedState<Self> {
                todo!()
            }

            #[inline]
            fn deserialize(
                serialized_state: &$crate::crypto_common::hazmat::SerializedState<Self>,
            ) -> Result<Self, $crate::crypto_common::hazmat::DeserializeStateError> {
                todo!()
            }
        }
    };
}
