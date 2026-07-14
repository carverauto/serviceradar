
use procfs_core::ProcResult;
pub use procfs_core::CryptoTable;

use crate::Current;

impl Current for CryptoTable {
    const PATH: &'static str = "/proc/crypto";
}

pub fn crypto() -> ProcResult<CryptoTable> {
    CryptoTable::current()
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_crypto() {
        let table = crypto();
        let table = table.expect("CrytoTable should have been read");
        assert!(!table.crypto_blocks.is_empty(), "Crypto table was empty");
    }
}