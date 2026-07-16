//! Low-level traits operating on blocks and wrappers around them.
//!
//! Usage of traits in this module in user code is discouraged. Instead use
//! core algorithm wrapped by the wrapper types, which implement the
//! higher-level traits.
use crate::{Digest, HashMarker, InvalidOutputSize};

pub use block_buffer::{Eager, Lazy};
pub use common::{AlgorithmName, Block, BlockSizeUser, OutputSizeUser, Reset};

use block_buffer::{BlockBuffer, BlockSizes, BufferKind};
use common::Output;

mod ct_variable;
pub use ct_variable::CtOutWrapper;

/// Buffer type used by type which implements [`BufferKindUser`].
pub type Buffer<S> =
    BlockBuffer<<S as BlockSizeUser>::BlockSize, <S as BufferKindUser>::BufferKind>;

/// Types which consume data in blocks.
pub trait UpdateCore: BlockSizeUser {
    /// Update state using the provided data blocks.
    fn update_blocks(&mut self, blocks: &[Block<Self>]);
}

/// Sub-trait of [`BlockSizeUser`] implemented if `BlockSize` is
/// bigger than `U0` and smaller than `U256`.
///
/// This trait relies on the hack suggested [here][0] to work around
/// the long standing Rust issue regarding non-propagation of `where` bounds.
///
/// [0]: https://github.com/rust-lang/rust/issues/20671#issuecomment-1905186183
pub trait SmallBlockSizeUser:
    BlockSizeUser<BlockSize = <Self as SmallBlockSizeUser>::_BlockSize>
{
    /// Helper associated type equal to `<Self as BlockSizeUser>::BlockSize`.
    type _BlockSize: BlockSizes;
}

impl<T: BlockSizeUser> SmallBlockSizeUser for T
where
    T::BlockSize: BlockSizes,
{
    type _BlockSize = T::BlockSize;
}

/// Types which use [`BlockBuffer`] functionality.
pub trait BufferKindUser: SmallBlockSizeUser {
    /// Block buffer kind over which type operates.
    type BufferKind: BufferKind;
}

/// Trait implemented by eager hashes which expose their block-level core.
pub trait EagerHash: SmallBlockSizeUser + Digest + Clone {
    /// Block-level core type of the hash.
    type Core: HashMarker
        + UpdateCore
        + FixedOutputCore
        + SmallBlockSizeUser<_BlockSize = <Self as SmallBlockSizeUser>::_BlockSize>
        + BufferKindUser<BufferKind = Eager>
        + Default
        + Clone;
}

impl<T> EagerHash for T
where
    T: CoreProxy + SmallBlockSizeUser + Digest + Clone,
    <T as CoreProxy>::Core: HashMarker
        + UpdateCore
        + FixedOutputCore
        + SmallBlockSizeUser<_BlockSize = <T as SmallBlockSizeUser>::_BlockSize>
        + BufferKindUser<BufferKind = Eager>
        + Default
        + Clone,
{
    type Core = T::Core;
}

/// Core trait for hash functions with fixed output size.
pub trait FixedOutputCore: UpdateCore + BufferKindUser + OutputSizeUser {
    /// Finalize state using remaining data stored in the provided block buffer,
    /// write result into provided array and leave `self` in a dirty state.
    fn finalize_fixed_core(&mut self, buffer: &mut Buffer<Self>, out: &mut Output<Self>);
}

/// Core trait for hash functions with extendable (XOF) output size.
pub trait ExtendableOutputCore: UpdateCore + BufferKindUser {
    /// XOF reader core state.
    type ReaderCore: XofReaderCore;

    /// Retrieve XOF reader using remaining data stored in the block buffer
    /// and leave hasher in a dirty state.
    fn finalize_xof_core(&mut self, buffer: &mut Buffer<Self>) -> Self::ReaderCore;
}

/// Core reader trait for extendable-output function (XOF) result.
pub trait XofReaderCore: BlockSizeUser {
    /// Read next XOF block.
    fn read_block(&mut self) -> Block<Self>;
}

/// Core trait for hash functions with variable output size.
///
/// Maximum output size is equal to [`OutputSizeUser::OutputSize`].
/// Users are expected to truncate result returned by the
/// [`finalize_variable_core`] to `output_size` passed to the [`new`] method
/// during construction. Truncation side is defined by the [`TRUNC_SIDE`]
/// associated constant.
///
/// [`finalize_variable_core`]: VariableOutputCore::finalize_variable_core
/// [`new`]: VariableOutputCore::new
/// [`TRUNC_SIDE`]: VariableOutputCore::TRUNC_SIDE
pub trait VariableOutputCore: UpdateCore + OutputSizeUser + BufferKindUser + Sized {
    /// Side which should be used in a truncated result.
    const TRUNC_SIDE: TruncSide;

    /// Initialize hasher state for given output size.
    ///
    /// # Errors
    /// Returns [`InvalidOutputSize`] if `output_size` is not valid for
    /// the algorithm, e.g. if it's bigger than the [`OutputSize`]
    /// associated type.
    ///
    /// [`OutputSize`]: OutputSizeUser::OutputSize
    fn new(output_size: usize) -> Result<Self, InvalidOutputSize>;

    /// Finalize hasher and write full hashing result into the `out` buffer.
    ///
    /// The result must be truncated to `output_size` used during hasher
    /// construction. Truncation side is defined by the [`TRUNC_SIDE`]
    /// associated constant.
    ///
    /// [`TRUNC_SIDE`]: VariableOutputCore::TRUNC_SIDE
    fn finalize_variable_core(&mut self, buffer: &mut Buffer<Self>, out: &mut Output<Self>);
}

/// Trait adding customization string to hash functions with variable output.
pub trait VariableOutputCoreCustomized: VariableOutputCore {
    /// Create new hasher instance with the given customization string and output size.
    fn new_customized(customization: &[u8], output_size: usize) -> Self;
}

/// Type which used for defining truncation side in the [`VariableOutputCore`]
/// trait.
#[derive(Copy, Clone, Debug)]
pub enum TruncSide {
    /// Truncate left side, i.e. `&out[..n]`.
    Left,
    /// Truncate right side, i.e. `&out[m..]`.
    Right,
}

/// A proxy trait to the core block-level type.
pub trait CoreProxy {
    /// Core block-level type.
    type Core: BufferKindUser;

    /// Create `Self` from core and buffer.
    fn compose(core: Self::Core, buffer: Buffer<Self::Core>) -> Self;
    /// Decompose `self` into core and buffer.
    fn decompose(self) -> (Self::Core, Buffer<Self::Core>);
}
