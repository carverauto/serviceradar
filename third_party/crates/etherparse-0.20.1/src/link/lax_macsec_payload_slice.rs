use crate::*;

#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub enum LaxMacsecPayloadSlice<'a> {
    /// Unencrypted unmodified ether payload.
    Unmodified(LaxEtherPayloadSlice<'a>),

    /// Modified payload (either by encryption or other algorithm).
    Modified { incomplete: bool, payload: &'a [u8] },
}
