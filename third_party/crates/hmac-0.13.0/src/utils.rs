use digest::{
    Digest,
    block_api::{Block, BlockSizeUser},
};

pub(crate) const IPAD: u8 = 0x36;
pub(crate) const OPAD: u8 = 0x5C;

pub(crate) fn get_der_key<D: Digest + BlockSizeUser>(key: &[u8]) -> Block<D> {
    let mut der_key = Block::<D>::default();
    // The key that HMAC processes must be the same as the block size of the
    // underlying hash function. If the provided key is smaller than that,
    // we just pad it with zeros. If its larger, we hash it and then pad it
    // with zeros.
    if key.len() <= der_key.len() {
        der_key[..key.len()].copy_from_slice(key);
    } else {
        let hash = D::digest(key);
        // All commonly used hash functions have block size bigger
        // than output hash size, but to be extra rigorous we
        // handle the potential uncommon cases as well.
        // The condition is calculated at compile time, so this
        // branch gets removed from the final binary.
        if hash.len() <= der_key.len() {
            der_key[..hash.len()].copy_from_slice(&hash);
        } else {
            let n = der_key.len();
            der_key.copy_from_slice(&hash[..n]);
        }
    }
    der_key
}
