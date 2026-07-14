//! Macros used to define traits on aliases of `Uint`.

// TODO(tarcieri): use `generic_const_exprs` when stable to make generic around bits.
macro_rules! impl_uint_aliases {
    ($(($name:ident, $bits:expr, $doc:expr)),+) => {
        $(
            #[doc = $doc]
            #[doc="unsigned big integer."]
            pub type $name = Uint<{ nlimbs!($bits) }>;

            impl $name {
                /// Serialize as big endian bytes.
                pub const fn to_be_bytes(&self) -> [u8; $bits / 8] {
                    encoding::uint_to_be_bytes::<{ nlimbs!($bits) }, { $bits / 8 }>(self)
                }

                /// Serialize as little endian bytes.
                pub const fn to_le_bytes(&self) -> [u8; $bits / 8] {
                    encoding::uint_to_le_bytes::<{ nlimbs!($bits) }, { $bits / 8 }>(self)
                }
            }

            impl Encoding for $name {
                type Repr = [u8; $bits / 8];

                #[inline]
                fn from_be_bytes(bytes: Self::Repr) -> Self {
                    Self::from_be_slice(&bytes)
                }

                #[inline]
                fn from_le_bytes(bytes: Self::Repr) -> Self {
                    Self::from_le_slice(&bytes)
                }

                #[inline]
                fn to_be_bytes(&self) -> Self::Repr {
                    encoding::uint_to_be_bytes(self)
                }

                #[inline]
                fn to_le_bytes(&self) -> Self::Repr {
                    encoding::uint_to_le_bytes(self)
                }
            }
        )+
     };
}

macro_rules! impl_uint_concat_split_mixed {
    ($name:ident, $size:literal) => {
        impl $crate::traits::ConcatMixed<Uint<{ U64::LIMBS * $size }>> for Uint<{ <$name>::LIMBS - U64::LIMBS * $size }>
        {
            type MixedOutput = $name;

            fn concat_mixed(&self, hi: &Uint<{ U64::LIMBS * $size }>) -> Self::MixedOutput {
                Uint::concat_mixed(self, hi)
            }
        }

        impl $crate::traits::SplitMixed<Uint<{ U64::LIMBS * $size }>, Uint<{ <$name>::LIMBS - U64::LIMBS * $size }>> for $name
        {
            fn split_mixed(&self) -> (Uint<{ U64::LIMBS * $size }>, Uint<{ <$name>::LIMBS - U64::LIMBS * $size }>) {
                self.split_mixed()
            }
        }

        impl $crate::traits::RemMixed<Uint<{ U64::LIMBS * $size }>> for $name
        {
            fn rem_mixed(&self, reductor: &NonZero<Uint<{ U64::LIMBS * $size }>>) -> Uint<{ U64::LIMBS * $size }> {
                self.div_rem_vartime(reductor).1
            }
        }
    };
    ($name:ident, [ $($size:literal),+ ]) => {
        $(
            impl_uint_concat_split_mixed!($name, $size);
        )+
    };
    ($( ($name:ident, $sizes:tt), )+) => {
        $(
            impl_uint_concat_split_mixed!($name, $sizes);
        )+
    };
}

macro_rules! impl_uint_concat_split_even {
    ($name:ident) => {
        impl $crate::traits::ConcatMixed<Uint<{ <$name>::LIMBS / 2 }>> for Uint<{ <$name>::LIMBS / 2 }>
        {
            type MixedOutput = $name;

            fn concat_mixed(&self, hi: &Uint<{ <$name>::LIMBS / 2 }>) -> Self::MixedOutput {
                Uint::concat_mixed(self, hi)
            }
        }

        impl $crate::traits::SplitMixed<Uint<{ <$name>::LIMBS / 2 }>, Uint<{ <$name>::LIMBS / 2 }>> for $name
        {
            fn split_mixed(&self) -> (Uint<{ <$name>::LIMBS / 2 }>, Uint<{ <$name>::LIMBS / 2 }>) {
                self.split_mixed()
            }
        }

        impl $crate::traits::RemMixed<Uint<{ <$name>::LIMBS / 2 }>> for $name
        {
            fn rem_mixed(&self, reductor: &NonZero<Uint<{ <$name>::LIMBS / 2 }>>) -> Uint<{ <$name>::LIMBS / 2 }> {
                self.div_rem_vartime(reductor).1
            }
        }

        impl $crate::traits::Split for $name
        {
            type Output = Uint<{ <$name>::LIMBS / 2 }>;
        }
    };
    ($($name:ident,)+) => {
        $(
            impl_uint_concat_split_even!($name);
        )+
    }
}
