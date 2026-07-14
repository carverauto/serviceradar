// This macro is not used by the soft backend, to simplify the crate code we allow this macro
// to be unused to prevent warnings e.g. when `force-soft` is enabled/
#[allow(unused_macros)]
macro_rules! impl_backends {
    (
        enc_name = $enc_name:ident,
        dec_name = $dec_name:ident,
        key_size = $key_size:ty,
        keys_ty = $keys_ty:ty,
        par_size = $par_size:ty,
        expand_keys = $expand_keys:expr,
        inv_keys = $inv_keys:expr,
        encrypt = $encrypt:expr,
        encrypt_par = $encrypt_par:expr,
        decrypt = $decrypt:expr,
        decrypt_par = $decrypt_par:expr,
) => {
        #[derive(Clone)]
        pub(crate) struct $enc_name {
            keys: $keys_ty,
        }

        impl cipher::BlockSizeUser for $enc_name {
            type BlockSize = cipher::consts::U16;
        }

        impl cipher::ParBlocksSizeUser for $enc_name {
            type ParBlocksSize = $par_size;
        }

        impl cipher::KeySizeUser for $enc_name {
            type KeySize = $key_size;
        }

        impl cipher::KeyInit for $enc_name {
            #[inline]
            fn new(key: &cipher::Key<Self>) -> Self {
                let keys = unsafe { $expand_keys(key.as_ref()) };
                Self { keys }
            }
        }

        impl cipher::BlockCipherEncBackend for $enc_name {
            #[inline(always)]
            fn encrypt_block(&self, block: cipher::inout::InOut<'_, '_, cipher::Block<Self>>) {
                unsafe { $encrypt(&self.keys, block) }
            }

            #[inline(always)]
            fn encrypt_par_blocks(
                &self,
                blocks: cipher::inout::InOut<'_, '_, cipher::ParBlocks<Self>>,
            ) {
                unsafe { $encrypt_par(&self.keys, blocks) }
            }
        }

        #[derive(Clone)]
        pub(crate) struct $dec_name {
            keys: $keys_ty,
        }

        impl cipher::BlockSizeUser for $dec_name {
            type BlockSize = cipher::consts::U16;
        }

        impl cipher::ParBlocksSizeUser for $dec_name {
            type ParBlocksSize = $par_size;
        }

        impl cipher::KeySizeUser for $dec_name {
            type KeySize = $key_size;
        }

        impl cipher::KeyInit for $dec_name {
            #[inline]
            fn new(key: &cipher::Key<Self>) -> Self {
                From::from($enc_name::new(key))
            }
        }

        impl From<$enc_name> for $dec_name {
            #[inline]
            fn from(enc: $enc_name) -> $dec_name {
                let keys = unsafe { $inv_keys(&enc.keys) };
                Self { keys }
            }
        }

        impl cipher::BlockCipherDecBackend for $dec_name {
            #[inline(always)]
            fn decrypt_block(&self, block: cipher::inout::InOut<'_, '_, cipher::Block<Self>>) {
                unsafe { $decrypt(&self.keys, block) }
            }

            #[inline(always)]
            fn decrypt_par_blocks(
                &self,
                blocks: cipher::inout::InOut<'_, '_, cipher::ParBlocks<Self>>,
            ) {
                unsafe { $decrypt_par(&self.keys, blocks) }
            }
        }
    };
}
