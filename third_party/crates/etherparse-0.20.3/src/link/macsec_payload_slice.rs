use super::EtherPayloadSlice;

#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub enum MacsecPayloadSlice<'a> {
    /// Unencrypted unmodified ether payload.
    Unmodified(EtherPayloadSlice<'a>),

    /// Modified payload (either by encryption or other algorithm).
    Modified(&'a [u8]),
}
