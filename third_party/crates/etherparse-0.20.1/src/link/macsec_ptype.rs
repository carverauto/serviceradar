use super::EtherType;

/// Encryption & modification state of the payload
/// of a mac sec packet including the next ether type if
/// the payload is unencrypted & unmodified.
#[derive(Copy, Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub enum MacsecPType {
    /// Unencrypted & unmodified (`!tci.c && !tci.e`) containing
    /// the ether type of the after the mac sec.
    Unmodified(EtherType),

    /// Unencrypted but modified payload (`tci.c && !tci.e`).
    Modified,

    /// Encrypted and modified payload (`tci.c && tci.e`).
    Encrypted,

    /// Encrypted and unmodified payload (`tci.c && !tci.e`).
    /// This is not normal behavior.
    ///
    /// Normally if the "encryption" flag should always be set
    /// together with the modification flag.
    EncryptedUnmodified,
}
