//! USB Serial Communication

unsafe extern "system" {
    pub fn vexSerialWriteChar(channel: u32, c: u8) -> i32;
    pub fn vexSerialWriteBuffer(channel: u32, data: *const u8, data_len: u32) -> i32;
    pub fn vexSerialReadChar(channel: u32) -> i32;
    pub fn vexSerialPeekChar(channel: u32) -> i32;
    pub fn vexSerialWriteFree(channel: u32) -> i32;
}
