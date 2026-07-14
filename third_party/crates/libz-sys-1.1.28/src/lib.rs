#![allow(non_camel_case_types)]
#![allow(non_snake_case)]

use std::os::raw::{c_char, c_int, c_long, c_uchar, c_uint, c_ulong, c_void};

// Macro for variances between zlib-ng in native mode and either zlib or zlib-ng in zlib compat
// mode. Note in particular that zlib-ng in compat mode does *not* use the zng case.
#[cfg(not(zng))]
macro_rules! if_zng {
    ($_zng:tt, $not_zng:tt) => {
        $not_zng
    };
}

#[cfg(zng)]
macro_rules! if_zng {
    ($zng:tt, $_not_zng:tt) => {
        $zng
    };
}

// zlib uses unsigned long for various sizes; zlib-ng uses size_t.
type z_size = if_zng!(usize, c_ulong);

// zlib stores Adler-32 and CRC-32 checksums in unsigned long; zlib-ng uses uint32_t.
type z_checksum = if_zng!(u32, c_ulong);

pub type alloc_func = unsafe extern "C" fn(voidpf, uInt, uInt) -> voidpf;
pub type Bytef = u8;
pub type free_func = unsafe extern "C" fn(voidpf, voidpf);
#[cfg(any(zng, feature = "libc"))]
pub type gzFile = *mut gzFile_s;
pub type in_func = unsafe extern "C" fn(*mut c_void, *mut *const c_uchar) -> c_uint;
pub type out_func = unsafe extern "C" fn(*mut c_void, *mut c_uchar, c_uint) -> c_int;
pub type uInt = c_uint;
pub type uLong = c_ulong;
pub type uLongf = c_ulong;
pub type voidp = *mut c_void;
pub type voidpc = *const c_void;
pub type voidpf = *mut c_void;

#[cfg(any(zng, feature = "libc"))]
pub enum gzFile_s {}
pub enum internal_state {}

#[cfg(all(
    not(zng),
    feature = "libc",
    not(all(target_family = "wasm", target_os = "unknown"))
))]
pub type z_off_t = libc::off_t;

#[cfg(all(
    not(zng),
    feature = "libc",
    all(target_family = "wasm", target_os = "unknown")
))]
pub type z_off_t = c_long;

#[cfg(all(zng, windows, not(target_env = "gnu")))]
pub type z_off_t = i64;

#[cfg(all(zng, not(all(windows, not(target_env = "gnu")))))]
pub type z_off_t = libc::off_t;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct gz_header {
    pub text: c_int,
    pub time: uLong,
    pub xflags: c_int,
    pub os: c_int,
    pub extra: *mut Bytef,
    pub extra_len: uInt,
    pub extra_max: uInt,
    pub name: *mut Bytef,
    pub name_max: uInt,
    pub comment: *mut Bytef,
    pub comm_max: uInt,
    pub hcrc: c_int,
    pub done: c_int,
}
pub type gz_headerp = *mut gz_header;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct z_stream {
    pub next_in: *mut Bytef,
    pub avail_in: uInt,
    pub total_in: z_size,
    pub next_out: *mut Bytef,
    pub avail_out: uInt,
    pub total_out: z_size,
    pub msg: *mut c_char,
    pub state: *mut internal_state,
    pub zalloc: alloc_func,
    pub zfree: free_func,
    pub opaque: voidpf,
    pub data_type: c_int,
    pub adler: z_checksum,
    pub reserved: uLong,
}
pub type z_streamp = *mut z_stream;

// Ideally, this should instead use a macro that parses the whole block of externs, and generates
// the appropriate link_name attributes, without duplicating the function names. However, ctest2
// can't parse that.
#[cfg(not(zng))]
macro_rules! zng_prefix {
    ($name:expr) => {
        stringify!($name)
    };
}

#[cfg(zng)]
macro_rules! zng_prefix {
    ($name:expr) => {
        concat!("zng_", stringify!($name))
    };
}

extern "C" {
    #[link_name = zng_prefix!(adler32)]
    pub fn adler32(adler: z_checksum, buf: *const Bytef, len: uInt) -> z_checksum;
    #[link_name = zng_prefix!(crc32)]
    pub fn crc32(crc: z_checksum, buf: *const Bytef, len: uInt) -> z_checksum;
    #[link_name = zng_prefix!(deflate)]
    pub fn deflate(strm: z_streamp, flush: c_int) -> c_int;
    #[link_name = zng_prefix!(deflateBound)]
    pub fn deflateBound(strm: z_streamp, sourceLen: uLong) -> uLong;
    #[link_name = zng_prefix!(deflateCopy)]
    pub fn deflateCopy(dest: z_streamp, source: z_streamp) -> c_int;
    #[link_name = zng_prefix!(deflateEnd)]
    pub fn deflateEnd(strm: z_streamp) -> c_int;
    #[link_name = zng_prefix!(deflateParams)]
    pub fn deflateParams(strm: z_streamp, level: c_int, strategy: c_int) -> c_int;
    #[link_name = zng_prefix!(deflatePrime)]
    pub fn deflatePrime(strm: z_streamp, bits: c_int, value: c_int) -> c_int;
    #[link_name = zng_prefix!(deflateReset)]
    pub fn deflateReset(strm: z_streamp) -> c_int;
    #[link_name = zng_prefix!(deflateSetDictionary)]
    pub fn deflateSetDictionary(
        strm: z_streamp,
        dictionary: *const Bytef,
        dictLength: uInt,
    ) -> c_int;
    #[link_name = zng_prefix!(deflateSetHeader)]
    pub fn deflateSetHeader(strm: z_streamp, head: gz_headerp) -> c_int;
    #[link_name = zng_prefix!(deflateTune)]
    pub fn deflateTune(
        strm: z_streamp,
        good_length: c_int,
        max_lazy: c_int,
        nice_length: c_int,
        max_chain: c_int,
    ) -> c_int;
    #[link_name = zng_prefix!(inflate)]
    pub fn inflate(strm: z_streamp, flush: c_int) -> c_int;
    #[link_name = zng_prefix!(inflateBack)]
    pub fn inflateBack(
        strm: z_streamp,
        _in: in_func,
        in_desc: *mut c_void,
        out: out_func,
        out_desc: *mut c_void,
    ) -> c_int;
    #[link_name = zng_prefix!(inflateBackEnd)]
    pub fn inflateBackEnd(strm: z_streamp) -> c_int;
    #[link_name = zng_prefix!(inflateCopy)]
    pub fn inflateCopy(dest: z_streamp, source: z_streamp) -> c_int;
    #[link_name = zng_prefix!(inflateEnd)]
    pub fn inflateEnd(strm: z_streamp) -> c_int;
    #[link_name = zng_prefix!(inflateGetHeader)]
    pub fn inflateGetHeader(strm: z_streamp, head: gz_headerp) -> c_int;
    #[link_name = zng_prefix!(inflateMark)]
    pub fn inflateMark(strm: z_streamp) -> c_long;
    #[link_name = zng_prefix!(inflatePrime)]
    pub fn inflatePrime(strm: z_streamp, bits: c_int, value: c_int) -> c_int;
    #[link_name = zng_prefix!(inflateReset)]
    pub fn inflateReset(strm: z_streamp) -> c_int;
    #[link_name = zng_prefix!(inflateReset2)]
    pub fn inflateReset2(strm: z_streamp, windowBits: c_int) -> c_int;
    #[link_name = zng_prefix!(inflateSetDictionary)]
    pub fn inflateSetDictionary(
        strm: z_streamp,
        dictionary: *const Bytef,
        dictLength: uInt,
    ) -> c_int;
    #[link_name = zng_prefix!(inflateSync)]
    pub fn inflateSync(strm: z_streamp) -> c_int;
    #[link_name = zng_prefix!(zlibCompileFlags)]
    pub fn zlibCompileFlags() -> uLong;

    // The above set of functions currently target 1.2.3.4 (what's present on Ubuntu
    // 12.04, but there's some other APIs that were added later. Should figure out
    // how to expose them...
    //
    // Added in 1.2.5.1
    //
    //     pub fn deflatePending(strm: z_streamp,
    //                           pending: *mut c_uint,
    //                           bits: *mut c_int) -> c_int;
    //
    // Addedin 1.2.7.1
    //     pub fn inflateGetDictionary(strm: z_streamp,
    //                                 dictionary: *mut Bytef,
    //                                 dictLength: *mut uInt) -> c_int;
    //
    // Added in 1.2.3.5
    //     pub fn gzbuffer(file: gzFile, size: c_uint) -> c_int;
    //     pub fn gzclose_r(file: gzFile) -> c_int;
    //     pub fn gzclose_w(file: gzFile) -> c_int;
    //     pub fn gzoffset(file: gzFile) -> z_off_t;
}

extern "C" {
    #[link_name = if_zng!("zlibng_version", "zlibVersion")]
    pub fn zlibVersion() -> *const c_char;
}

#[cfg(not(zng))]
extern "C" {
    pub fn deflateInit_(
        strm: z_streamp,
        level: c_int,
        version: *const c_char,
        stream_size: c_int,
    ) -> c_int;
    pub fn deflateInit2_(
        strm: z_streamp,
        level: c_int,
        method: c_int,
        windowBits: c_int,
        memLevel: c_int,
        strategy: c_int,
        version: *const c_char,
        stream_size: c_int,
    ) -> c_int;
    pub fn inflateBackInit_(
        strm: z_streamp,
        windowBits: c_int,
        window: *mut c_uchar,
        version: *const c_char,
        stream_size: c_int,
    ) -> c_int;
    pub fn inflateInit_(strm: z_streamp, version: *const c_char, stream_size: c_int) -> c_int;
    pub fn inflateInit2_(
        strm: z_streamp,
        windowBits: c_int,
        version: *const c_char,
        stream_size: c_int,
    ) -> c_int;
}

#[cfg(zng)]
extern "C" {
    pub fn zng_deflateInit(strm: z_streamp, level: c_int) -> c_int;
    pub fn zng_deflateInit2(
        strm: z_streamp,
        level: c_int,
        method: c_int,
        windowBits: c_int,
        memLevel: c_int,
        strategy: c_int,
    ) -> c_int;
    pub fn zng_inflateBackInit(strm: z_streamp, windowBits: c_int, window: *mut c_uchar) -> c_int;
    pub fn zng_inflateInit(strm: z_streamp) -> c_int;
    pub fn zng_inflateInit2(strm: z_streamp, windowBits: c_int) -> c_int;
}

// These methods are required to keep BC with original zlib API since zlib-ng 2.1 that changed API
#[cfg(zng)]
#[inline(always)]
pub unsafe fn inflateInit2_(
    strm: z_streamp,
    windowBits: c_int,
    _version: *const c_char,
    _stream_size: c_int,
) -> c_int {
    zng_inflateInit2(strm, windowBits)
}

#[cfg(zng)]
#[inline(always)]
pub unsafe fn inflateInit_(strm: z_streamp, _version: *const c_char, _stream_size: c_int) -> c_int {
    zng_inflateInit(strm)
}

#[cfg(zng)]
#[inline(always)]
pub unsafe fn inflateBackInit_(
    strm: z_streamp,
    windowBits: c_int,
    window: *mut c_uchar,
    _version: *const c_char,
    _stream_size: c_int,
) -> c_int {
    zng_inflateBackInit(strm, windowBits, window)
}

#[cfg(zng)]
#[inline(always)]
pub unsafe fn deflateInit2_(
    strm: z_streamp,
    level: c_int,
    method: c_int,
    windowBits: c_int,
    memLevel: c_int,
    strategy: c_int,
    _version: *const c_char,
    _stream_size: c_int,
) -> c_int {
    zng_deflateInit2(strm, level, method, windowBits, memLevel, strategy)
}

#[cfg(zng)]
#[inline]
pub unsafe fn deflateInit_(
    strm: z_streamp,
    level: c_int,
    _version: *const c_char,
    _stream_size: c_int,
) -> c_int {
    zng_deflateInit(strm, level)
}

#[cfg(any(zng, feature = "libc"))]
extern "C" {
    #[link_name = zng_prefix!(adler32_combine)]
    pub fn adler32_combine(adler1: z_checksum, adler2: z_checksum, len2: z_off_t) -> z_checksum;
    #[link_name = zng_prefix!(compress)]
    pub fn compress(
        dest: *mut Bytef,
        destLen: *mut z_size,
        source: *const Bytef,
        sourceLen: z_size,
    ) -> c_int;
    #[link_name = zng_prefix!(compress2)]
    pub fn compress2(
        dest: *mut Bytef,
        destLen: *mut z_size,
        source: *const Bytef,
        sourceLen: z_size,
        level: c_int,
    ) -> c_int;
    #[link_name = zng_prefix!(compressBound)]
    pub fn compressBound(sourceLen: z_size) -> z_size;
    #[link_name = zng_prefix!(crc32_combine)]
    pub fn crc32_combine(crc1: z_checksum, crc2: z_checksum, len2: z_off_t) -> z_checksum;
    #[link_name = zng_prefix!(gzdirect)]
    pub fn gzdirect(file: gzFile) -> c_int;
    #[link_name = zng_prefix!(gzdopen)]
    pub fn gzdopen(fd: c_int, mode: *const c_char) -> gzFile;
    #[link_name = zng_prefix!(gzclearerr)]
    pub fn gzclearerr(file: gzFile);
    #[link_name = zng_prefix!(gzclose)]
    pub fn gzclose(file: gzFile) -> c_int;
    #[link_name = zng_prefix!(gzeof)]
    pub fn gzeof(file: gzFile) -> c_int;
    #[link_name = zng_prefix!(gzerror)]
    pub fn gzerror(file: gzFile, errnum: *mut c_int) -> *const c_char;
    #[link_name = zng_prefix!(gzflush)]
    pub fn gzflush(file: gzFile, flush: c_int) -> c_int;
    #[link_name = zng_prefix!(gzgetc)]
    pub fn gzgetc(file: gzFile) -> c_int;
    #[link_name = zng_prefix!(gzgets)]
    pub fn gzgets(file: gzFile, buf: *mut c_char, len: c_int) -> *mut c_char;
    #[link_name = zng_prefix!(gzopen)]
    pub fn gzopen(path: *const c_char, mode: *const c_char) -> gzFile;
    #[link_name = zng_prefix!(gzputc)]
    pub fn gzputc(file: gzFile, c: c_int) -> c_int;
    #[link_name = zng_prefix!(gzputs)]
    pub fn gzputs(file: gzFile, s: *const c_char) -> c_int;
    #[link_name = zng_prefix!(gzread)]
    pub fn gzread(file: gzFile, buf: voidp, len: c_uint) -> c_int;
    #[link_name = zng_prefix!(gzrewind)]
    pub fn gzrewind(file: gzFile) -> c_int;
    #[link_name = zng_prefix!(gzseek)]
    pub fn gzseek(file: gzFile, offset: z_off_t, whence: c_int) -> z_off_t;
    #[link_name = zng_prefix!(gzsetparams)]
    pub fn gzsetparams(file: gzFile, level: c_int, strategy: c_int) -> c_int;
    #[link_name = zng_prefix!(gztell)]
    pub fn gztell(file: gzFile) -> z_off_t;
    #[link_name = zng_prefix!(gzungetc)]
    pub fn gzungetc(c: c_int, file: gzFile) -> c_int;
    #[link_name = zng_prefix!(gzwrite)]
    pub fn gzwrite(file: gzFile, buf: voidpc, len: c_uint) -> c_int;
    #[link_name = zng_prefix!(uncompress)]
    pub fn uncompress(
        dest: *mut Bytef,
        destLen: *mut z_size,
        source: *const Bytef,
        sourceLen: z_size,
    ) -> c_int;
}

pub const Z_NO_FLUSH: c_int = 0;
pub const Z_PARTIAL_FLUSH: c_int = 1;
pub const Z_SYNC_FLUSH: c_int = 2;
pub const Z_FULL_FLUSH: c_int = 3;
pub const Z_FINISH: c_int = 4;
pub const Z_BLOCK: c_int = 5;
pub const Z_TREES: c_int = 6;

pub const Z_OK: c_int = 0;
pub const Z_STREAM_END: c_int = 1;
pub const Z_NEED_DICT: c_int = 2;
pub const Z_ERRNO: c_int = -1;
pub const Z_STREAM_ERROR: c_int = -2;
pub const Z_DATA_ERROR: c_int = -3;
pub const Z_MEM_ERROR: c_int = -4;
pub const Z_BUF_ERROR: c_int = -5;
pub const Z_VERSION_ERROR: c_int = -6;

pub const Z_NO_COMPRESSION: c_int = 0;
pub const Z_BEST_SPEED: c_int = 1;
pub const Z_BEST_COMPRESSION: c_int = 9;
pub const Z_DEFAULT_COMPRESSION: c_int = -1;

pub const Z_FILTERED: c_int = 1;
pub const Z_HUFFMAN_ONLY: c_int = 2;
pub const Z_RLE: c_int = 3;
pub const Z_FIXED: c_int = 4;
pub const Z_DEFAULT_STRATEGY: c_int = 0;

pub const Z_BINARY: c_int = 0;
pub const Z_TEXT: c_int = 1;
pub const Z_ASCII: c_int = Z_TEXT;
pub const Z_UNKNOWN: c_int = 2;

pub const Z_DEFLATED: c_int = 8;
