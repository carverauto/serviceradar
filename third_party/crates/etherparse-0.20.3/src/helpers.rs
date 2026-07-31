/// Helper function for reading big endian u16 values from a ptr unchecked.
///
/// # Safety
///
/// It is in the responsibility of the caller to ensure there are at least 2
/// bytes accessable via the ptr. If this is not the case undefined behavior
/// will be triggered.
#[inline]
pub(crate) unsafe fn get_unchecked_be_u16(ptr: *const u8) -> u16 {
    u16::from_be_bytes([*ptr, *ptr.add(1)])
}

/// Helper function for reading big endian u32 values from a ptr unchecked.
///
/// # Safety
///
/// It is in the responsibility of the caller to ensure there are at least 4
/// bytes accessable via the ptr. If this is not the case undefined behavior
/// will be triggered.
#[inline]
pub(crate) unsafe fn get_unchecked_be_u32(ptr: *const u8) -> u32 {
    u32::from_be_bytes([*ptr, *ptr.add(1), *ptr.add(2), *ptr.add(3)])
}

/// Helper function for reading a 4 byte fixed-size array.
///
/// # Safety
///
/// It is in the responsibility of the caller to ensure there are at least 4
/// bytes accessable via the ptr. If this is not the case undefined behavior
/// will be triggered.
#[inline]
pub(crate) unsafe fn get_unchecked_4_byte_array(ptr: *const u8) -> [u8; 4] {
    [*ptr, *ptr.add(1), *ptr.add(2), *ptr.add(3)]
}

/// Helper function for reading a 6 byte fixed-size array.
///
/// # Safety
///
/// It is in the responsibility of the caller to ensure there are at least 6
/// bytes accessable via the ptr. If this is not the case undefined behavior
/// will be triggered.
#[inline]
pub(crate) unsafe fn get_unchecked_6_byte_array(ptr: *const u8) -> [u8; 6] {
    [
        *ptr,
        *ptr.add(1),
        *ptr.add(2),
        *ptr.add(3),
        *ptr.add(4),
        *ptr.add(5),
    ]
}

/// Helper function for reading a 8 byte fixed-size array.
///
/// # Safety
///
/// It is in the responsibility of the caller to ensure there are at least 6
/// bytes accessable via the ptr. If this is not the case undefined behavior
/// will be triggered.
#[inline]
pub(crate) unsafe fn get_unchecked_8_byte_array(ptr: *const u8) -> [u8; 8] {
    [
        *ptr,
        *ptr.add(1),
        *ptr.add(2),
        *ptr.add(3),
        *ptr.add(4),
        *ptr.add(5),
        *ptr.add(6),
        *ptr.add(7),
    ]
}

/// Helper function for reading a 16 byte fixed-size array.
///
/// # Safety
///
/// It is in the responsibility of the caller to ensure there are at least 16
/// bytes accessable via the ptr. If this is not the case undefined behavior
/// will be triggered.
#[inline]
pub(crate) unsafe fn get_unchecked_16_byte_array(ptr: *const u8) -> [u8; 16] {
    [
        *ptr,
        *ptr.add(1),
        *ptr.add(2),
        *ptr.add(3),
        *ptr.add(4),
        *ptr.add(5),
        *ptr.add(6),
        *ptr.add(7),
        *ptr.add(8),
        *ptr.add(9),
        *ptr.add(10),
        *ptr.add(11),
        *ptr.add(12),
        *ptr.add(13),
        *ptr.add(14),
        *ptr.add(15),
    ]
}
