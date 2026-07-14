//! Traits used to define functionality of [tweakable block ciphers][1].
//!
//! [1]: https://people.eecs.berkeley.edu/~daw/papers/tweak-crypto02.pdf
use crypto_common::{
    Block, BlockSizeUser,
    array::{Array, ArraySize},
};
use inout::InOut;

mod ctx;
mod zero;

pub use zero::ZeroTweak;

/// Tweak used by a [`TweakSizeUser`] implementor.
pub type Tweak<C> = Array<u8, <C as TweakSizeUser>::TweakSize>;

/// Trait which contains tweak size used by the tweak cipher traits.
pub trait TweakSizeUser {
    /// Size of the tweak in bytes.
    type TweakSize: ArraySize;
}

/// Encrypt-only functionality for tweakable block ciphers.
pub trait TweakBlockCipherEncrypt: BlockSizeUser + TweakSizeUser + Sized {
    /// Encrypt data using backend provided to the rank-2 closure.
    fn encrypt_with_backend(
        &self,
        f: impl TweakBlockCipherEncClosure<BlockSize = Self::BlockSize, TweakSize = Self::TweakSize>,
    );

    /// Encrypt single `inout` block.
    #[inline]
    fn encrypt_block_inout(&self, tweak: &Tweak<Self>, block: InOut<'_, '_, Block<Self>>) {
        self.encrypt_with_backend(ctx::BlockCtx { tweak, block });
    }

    /// Encrypt single block in-place.
    #[inline]
    fn encrypt_block(&self, tweak: &Tweak<Self>, block: &mut Block<Self>) {
        self.encrypt_block_inout(tweak, block.into());
    }

    /// Encrypt `in_block` and write result to `out_block`.
    #[inline]
    fn encrypt_block_b2b(
        &self,
        tweak: &Tweak<Self>,
        in_block: &Block<Self>,
        out_block: &mut Block<Self>,
    ) {
        self.encrypt_block_inout(tweak, (in_block, out_block).into());
    }
}

/// Decrypt-only functionality for tweakable block ciphers.
pub trait TweakBlockCipherDecrypt: BlockSizeUser + TweakSizeUser + Sized {
    /// Decrypt data using backend provided to the rank-2 closure.
    fn decrypt_with_backend(
        &self,
        f: impl TweakBlockCipherDecClosure<BlockSize = Self::BlockSize, TweakSize = Self::TweakSize>,
    );

    /// Decrypt single `inout` block.
    #[inline]
    fn decrypt_block_inout(&self, tweak: &Tweak<Self>, block: InOut<'_, '_, Block<Self>>) {
        self.decrypt_with_backend(ctx::BlockCtx { tweak, block });
    }

    /// Decrypt single block in-place.
    #[inline]
    fn decrypt_block(&self, tweak: &Tweak<Self>, block: &mut Block<Self>) {
        self.decrypt_block_inout(tweak, block.into());
    }

    /// Decrypt `in_block` and write result to `out_block`.
    #[inline]
    fn decrypt_block_b2b(
        &self,
        tweak: &Tweak<Self>,
        in_block: &Block<Self>,
        out_block: &mut Block<Self>,
    ) {
        self.decrypt_block_inout(tweak, (in_block, out_block).into());
    }
}

/// Trait for [`TweakBlockCipherEncBackend`] users.
///
/// This trait is used to define rank-2 closures.
pub trait TweakBlockCipherEncClosure: BlockSizeUser + TweakSizeUser {
    /// Execute closure with the provided block cipher backend.
    fn call<B>(self, backend: &B)
    where
        B: TweakBlockCipherEncBackend<BlockSize = Self::BlockSize, TweakSize = Self::TweakSize>;
}

/// Trait for [`TweakBlockCipherDecBackend`] users.
///
/// This trait is used to define rank-2 closures.
pub trait TweakBlockCipherDecClosure: BlockSizeUser + TweakSizeUser {
    /// Execute closure with the provided block cipher backend.
    fn call<B>(self, backend: &B)
    where
        B: TweakBlockCipherDecBackend<BlockSize = Self::BlockSize, TweakSize = Self::TweakSize>;
}

/// Trait implemented by block cipher mode encryption backends.
pub trait TweakBlockCipherEncBackend: BlockSizeUser + TweakSizeUser {
    /// Encrypt single inout block.
    fn encrypt_block_inout(&self, tweak: &Tweak<Self>, block: InOut<'_, '_, Block<Self>>);

    /// Encrypt single block in-place.
    #[inline]
    fn encrypt_block(&self, tweak: &Tweak<Self>, block: &mut Block<Self>) {
        self.encrypt_block_inout(tweak, block.into());
    }

    /// Encrypt `in_block` and write result to `out_block`.
    #[inline]
    fn encrypt_block_b2b(
        &self,
        tweak: &Tweak<Self>,
        in_block: &Block<Self>,
        out_block: &mut Block<Self>,
    ) {
        self.encrypt_block_inout(tweak, (in_block, out_block).into());
    }
}

/// Trait implemented by block cipher mode decryption backends.
pub trait TweakBlockCipherDecBackend: BlockSizeUser + TweakSizeUser {
    /// Decrypt single inout block.
    fn decrypt_block_inout(&self, tweak: &Tweak<Self>, block: InOut<'_, '_, Block<Self>>);

    /// Decrypt single block in-place.
    #[inline]
    fn decrypt_block(&self, tweak: &Tweak<Self>, block: &mut Block<Self>) {
        self.decrypt_block_inout(tweak, block.into());
    }

    /// Decrypt `in_block` and write result to `out_block`.
    #[inline]
    fn decrypt_block_b2b(
        &self,
        tweak: &Tweak<Self>,
        in_block: &Block<Self>,
        out_block: &mut Block<Self>,
    ) {
        self.decrypt_block_inout(tweak, (in_block, out_block).into());
    }
}
