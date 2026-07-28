//! Shared checked arithmetic for v9/IPFIX wire records.

/// Returns the minimum number of bytes one record must consume.
///
/// IPFIX variable-length fields consume at least their one-byte length prefix.
/// Pass `None` for fixed-width-only formats such as NetFlow v9.
pub(crate) fn minimum_record_size(
    widths: impl IntoIterator<Item = u16>,
    variable_length_marker: Option<u16>,
) -> Option<usize> {
    widths.into_iter().try_fold(0usize, |total, width| {
        let width = if variable_length_marker == Some(width) {
            1
        } else {
            usize::from(width)
        };
        total.checked_add(width)
    })
}

/// Padding is unambiguous only when it is shorter than a complete record.
pub(crate) fn is_short_padding(padding_len: usize, minimum_record_size: usize) -> bool {
    padding_len < minimum_record_size
}

/// NetFlow v9 additionally limits alignment padding to three bytes.
pub(crate) fn is_v9_padding(padding_len: usize, record_size: usize) -> bool {
    padding_len <= 3 && is_short_padding(padding_len, record_size)
}

#[derive(Clone, Copy)]
pub(crate) enum RecordBodyKind {
    NetFlowV9,
    Ipfix,
}

/// Require at least one decoded record and only protocol-valid padding.
pub(crate) fn record_body_is_complete(
    decoded_records: usize,
    remainder: &[u8],
    minimum_record_size: usize,
    kind: RecordBodyKind,
) -> bool {
    if decoded_records == 0 {
        return false;
    }
    match kind {
        RecordBodyKind::NetFlowV9 => is_v9_padding(remainder.len(), minimum_record_size),
        RecordBodyKind::Ipfix => is_short_padding(remainder.len(), minimum_record_size),
    }
}
