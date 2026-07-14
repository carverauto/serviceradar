/// Creates a buffered wrapper around block-level "core" type which implements variable output size traits
/// with output size selected at compile time.
#[macro_export]
macro_rules! buffer_ct_variable {
    (
        $(#[$attr:meta])*
        $vis:vis struct $name:ident<$out_size:ident>($core_ty:ty);
        exclude: SerializableState;
        // Ideally, we would use `$core_ty::OutputSize`, but unfortunately the compiler
        // does not accept such code. The likely reason is this issue:
        // https://github.com/rust-lang/rust/issues/79629
        max_size: $max_size:ty;
    ) => {
        $(#[$attr])*
        $vis struct $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            core: $crate::block_api::CtOutWrapper<$core_ty, $out_size>,
            buffer: $crate::block_api::Buffer<$core_ty>,
        }

        impl<$out_size> core::fmt::Debug for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            #[inline]
            fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                f.write_str(concat!(stringify!($name), " { ... }"))
            }
        }

        impl<$out_size> $crate::crypto_common::AlgorithmName for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            #[inline]
            fn write_alg_name(f: &mut core::fmt::Formatter<'_>) -> Result<(), core::fmt::Error> {
                <$core_ty as $crate::crypto_common::AlgorithmName>::write_alg_name(f)
            }
        }

        impl<$out_size> Clone for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            #[inline]
            fn clone(&self) -> Self {
                Self {
                    core: Clone::clone(&self.core),
                    buffer: Clone::clone(&self.buffer),
                }
            }
        }

        impl<$out_size> Default for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            #[inline]
            fn default() -> Self {
                Self {
                    core: Default::default(),
                    buffer: Default::default(),
                }
            }
        }

        impl<$out_size> $crate::Reset for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            #[inline]
            fn reset(&mut self) {
                $crate::Reset::reset(&mut self.core);
                self.buffer.reset();
            }
        }

        impl<$out_size> $crate::block_api::BlockSizeUser for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            type BlockSize = <$core_ty as $crate::crypto_common::BlockSizeUser>::BlockSize;
        }

        impl<$out_size> $crate::OutputSizeUser for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            type OutputSize = $out_size;
        }

        impl<$out_size> $crate::HashMarker for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {}

        // Verify that `$wrapped_ty` implements `HashMarker`
        const _: () = {
            fn check<$out_size>(v: &$core_ty)
            where
                $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size>,
                $crate::typenum::LeEq<$out_size, $max_size>: $crate::typenum::NonZero,
            {
                v as &dyn $crate::HashMarker;
            }
        };

        impl<$out_size> $crate::block_api::CoreProxy for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            type Core = $crate::block_api::CtOutWrapper<$core_ty, $out_size>;
            fn compose(core: Self::Core, buffer: $crate::block_api::Buffer<Self::Core>) -> Self {
                Self { core, buffer }
            }
            fn decompose(self) -> (Self::Core, $crate::block_api::Buffer<Self::Core>) {
                let Self { core, buffer } = self;
                (core, buffer)
            }
        }

        impl<$out_size> $crate::Update for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            #[inline]
            fn update(&mut self, data: &[u8]) {
                let Self { core, buffer } = self;
                buffer.digest_blocks(data, |blocks| {
                    $crate::block_api::UpdateCore::update_blocks(core, blocks)
                });
            }
        }

        impl<$out_size> $crate::FixedOutput for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            #[inline]
            fn finalize_into(mut self, out: &mut $crate::Output<Self>) {
                let Self { core, buffer } = &mut self;
                $crate::block_api::FixedOutputCore::finalize_fixed_core(core, buffer, out);
            }
        }

        impl<$out_size> $crate::FixedOutputReset for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
            #[inline]
            fn finalize_into_reset(&mut self, out: &mut $crate::Output<Self>) {
                let Self { core, buffer } = self;
                $crate::block_api::FixedOutputCore::finalize_fixed_core(core, buffer, out);
                $crate::Reset::reset(self);
            }
        }
    };
    (
        $(#[$attr:meta])*
        $vis:vis struct $name:ident<$out_size:ident>($core_ty:ty);
        // Ideally, we would use `$core_ty::OutputSize`, but unfortunately the compiler
        // does not accept such code. The likely reason is this issue:
        // https://github.com/rust-lang/rust/issues/79629
        max_size: $max_size:ty;
    ) => {
        $crate::buffer_ct_variable!(
            $(#[$attr])*
            $vis struct $name<$out_size>($core_ty);
            exclude: SerializableState;
            max_size: $max_size;
        );

        impl<$out_size> $crate::crypto_common::hazmat::SerializableState for $name<$out_size>
        where
            $out_size: $crate::array::ArraySize + $crate::typenum::IsLessOrEqual<$max_size, Output = $crate::typenum::True>,
        {
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
    };
}
