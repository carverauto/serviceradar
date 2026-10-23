//! A minimal, read-only reader for the SQLite file format, enough to scan the rows of one
//! rowid table. It exists so netprobe can read the rpm sqlite backend (`rpmdb.sqlite`)
//! without linking a SQLite library into a statically linked add-on.
//!
//! Scope, by design:
//! - rowid tables only (the rpm `Packages` table is one);
//! - the main database file plus its write-ahead log: committed WAL frames are read in
//!   place of the main file's pages, as a SQLite reader does, so a database whose last
//!   transactions are not yet checkpointed (or whose WAL persists after a checkpoint, as
//!   rpm configures it) reads as its last committed state. Frames after the last valid
//!   commit, or after the first frame whose salt or checksum does not match, are ignored;
//! - every offset is bounds-checked and every traversal is bounded by the page count, so a
//!   file that changes while it is read yields an error, not a panic or a loop.
//!
//! Format reference: <https://www.sqlite.org/fileformat2.html>.

use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fs::File;
use std::io;
#[cfg(unix)]
use std::os::unix::fs::FileExt;
use std::path::Path;

use super::root_path::open_regular;

const HEADER_MAGIC: &[u8; 16] = b"SQLite format 3\0";
const HEADER_LEN: usize = 100;
const PAGE_TABLE_INTERIOR: u8 = 0x05;
const PAGE_TABLE_LEAF: u8 = 0x0d;
/// Largest single row payload accepted. An rpm header is far below this.
const MAX_PAYLOAD_BYTES: u64 = 64 * 1024 * 1024;
const WAL_HEADER_LEN: usize = 32;
const WAL_FRAME_HEADER_LEN: usize = 24;
const WAL_MAGIC_LITTLE_ENDIAN: u32 = 0x377f_0682;
const WAL_MAGIC_BIG_ENDIAN: u32 = 0x377f_0683;
/// Largest write-ahead log read. A larger one makes the database unreadable rather than
/// silently stale.
const MAX_WAL_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum SqliteError {
    #[error("io: {0}")]
    Io(#[from] io::Error),
    #[error("not a sqlite database")]
    NotSqlite,
    #[error("malformed sqlite database: {0}")]
    Malformed(&'static str),
}

type Result<T> = std::result::Result<T, SqliteError>;

/// One decoded column value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    Null,
    Integer(i64),
    /// A floating-point column; its value is never needed here.
    Real,
    Text(Vec<u8>),
    Blob(Vec<u8>),
}

pub struct SqliteDatabase {
    file: File,
    wal: Option<Wal>,
    page_size: usize,
    usable_size: usize,
    page_count: u32,
}

/// The committed frames of a write-ahead log: the newest frame offset for each page.
struct Wal {
    file: File,
    pages: HashMap<u32, u64>,
    /// The database size in pages after the last committed transaction.
    page_count: u32,
}

impl SqliteDatabase {
    pub fn open(path: &Path) -> Result<Self> {
        let file = open_regular(path)?;
        let file_len = file.metadata()?.len();
        let mut header = [0u8; HEADER_LEN];
        read_exact_at(&file, &mut header, 0)?;
        if &header[..16] != HEADER_MAGIC {
            return Err(SqliteError::NotSqlite);
        }
        let page_size = match u16::from_be_bytes([header[16], header[17]]) {
            1 => 65_536,
            size if size >= 512 && size.is_power_of_two() => usize::from(size),
            _ => return Err(SqliteError::Malformed("page size")),
        };
        let reserved = usize::from(header[20]);
        let usable_size = page_size
            .checked_sub(reserved)
            .filter(|usable| *usable >= 480)
            .ok_or(SqliteError::Malformed("reserved space"))?;
        // The page count is derived from the file length rather than the in-header size,
        // which is only valid when the version-valid-for counter matches.
        let wal = Wal::open(&wal_path(path), page_size)?;
        let file_pages = u32::try_from(file_len / page_size as u64)
            .map_err(|_| SqliteError::Malformed("page count"))?;
        let page_count = match &wal {
            Some(wal)
                if u64::from(wal.page_count) > u64::from(file_pages) + wal.pages.len() as u64 =>
            {
                return Err(SqliteError::Malformed("write-ahead log database size"));
            }
            Some(wal) => wal.page_count,
            None => file_pages,
        };
        if page_count == 0 {
            return Err(SqliteError::Malformed("empty database"));
        }
        Ok(Self {
            file,
            wal,
            page_size,
            usable_size,
            page_count,
        })
    }

    /// Root page of the rowid table `name`, from the `sqlite_schema` table on page 1.
    pub fn table_root_page(&self, name: &str) -> Result<Option<u32>> {
        let mut root = None;
        self.scan_table(1, |_, columns| {
            let is_table = matches!(columns.first(), Some(Value::Text(kind)) if kind == b"table");
            let named =
                matches!(columns.get(1), Some(Value::Text(table)) if table == name.as_bytes());
            if is_table && named {
                if let Some(Value::Integer(page)) = columns.get(3) {
                    root = u32::try_from(*page).ok();
                }
                return false;
            }
            true
        })?;
        Ok(root)
    }

    /// Visits every row of the rowid table rooted at `root_page` in rowid order. The
    /// visitor returns `false` to stop early.
    pub fn scan_table(
        &self,
        root_page: u32,
        mut visit: impl FnMut(i64, Vec<Value>) -> bool,
    ) -> Result<()> {
        let mut stack = vec![root_page];
        let mut visited = HashSet::new();
        while let Some(page_number) = stack.pop() {
            self.mark_visited(&mut visited, page_number, "b-tree cycle")?;
            let page = self.read_page(page_number)?;
            let header_offset = if page_number == 1 { HEADER_LEN } else { 0 };
            let page_type = *page
                .get(header_offset)
                .ok_or(SqliteError::Malformed("page header"))?;
            let cell_count = usize::from(read_u16(&page, header_offset + 3)?);
            match page_type {
                PAGE_TABLE_LEAF => {
                    for index in 0..cell_count {
                        let cell = usize::from(read_u16(&page, header_offset + 8 + index * 2)?);
                        let (rowid, payload) = self.leaf_cell(&page, cell, &mut visited)?;
                        if !visit(rowid, decode_record(&payload)?) {
                            return Ok(());
                        }
                    }
                }
                PAGE_TABLE_INTERIOR => {
                    let right_most = read_u32(&page, header_offset + 8)?;
                    // Push in reverse so children are visited left to right.
                    stack.push(right_most);
                    for index in (0..cell_count).rev() {
                        let cell = usize::from(read_u16(&page, header_offset + 12 + index * 2)?);
                        stack.push(read_u32(&page, cell)?);
                    }
                }
                _ => return Err(SqliteError::Malformed("not a table b-tree page")),
            }
        }
        Ok(())
    }

    /// Records that `page_number` was read during one scan. Every page of a well-formed
    /// table belongs to exactly one b-tree node or overflow chain, so a repeat is a cycle.
    fn mark_visited(
        &self,
        visited: &mut HashSet<u32>,
        page_number: u32,
        error: &'static str,
    ) -> Result<()> {
        if !visited.insert(page_number) || visited.len() as u64 > u64::from(self.page_count) {
            return Err(SqliteError::Malformed(error));
        }
        Ok(())
    }

    fn leaf_cell(
        &self,
        page: &[u8],
        offset: usize,
        visited: &mut HashSet<u32>,
    ) -> Result<(i64, Vec<u8>)> {
        let (payload_len, used) = read_varint(page, offset)?;
        let (rowid, used_rowid) = read_varint(page, offset + used)?;
        if payload_len > MAX_PAYLOAD_BYTES {
            return Err(SqliteError::Malformed("payload too large"));
        }
        let payload_len = payload_len as usize;
        let start = offset + used + used_rowid;
        let local = self.local_payload_len(payload_len);
        let local_bytes = page
            .get(start..start + local)
            .ok_or(SqliteError::Malformed("cell payload"))?;
        let mut payload = Vec::with_capacity(payload_len);
        payload.extend_from_slice(local_bytes);

        if local < payload_len {
            let mut next = read_u32(page, start + local)?;
            let chunk = self.usable_size - 4;
            while payload.len() < payload_len {
                if next == 0 {
                    return Err(SqliteError::Malformed("overflow chain"));
                }
                self.mark_visited(visited, next, "overflow chain")?;
                let overflow = self.read_page(next)?;
                let take = chunk.min(payload_len - payload.len());
                payload.extend_from_slice(
                    overflow
                        .get(4..4 + take)
                        .ok_or(SqliteError::Malformed("overflow page"))?,
                );
                next = read_u32(&overflow, 0)?;
            }
        }
        Ok((rowid as i64, payload))
    }

    /// Bytes of a table-leaf payload stored on the b-tree page itself.
    fn local_payload_len(&self, payload_len: usize) -> usize {
        let usable = self.usable_size;
        let max_local = usable - 35;
        if payload_len <= max_local {
            return payload_len;
        }
        let min_local = ((usable - 12) * 32 / 255) - 23;
        let candidate = min_local + ((payload_len - min_local) % (usable - 4));
        if candidate <= max_local {
            candidate
        } else {
            min_local
        }
    }

    fn read_page(&self, page_number: u32) -> Result<Vec<u8>> {
        if page_number == 0 || page_number > self.page_count {
            return Err(SqliteError::Malformed("page number"));
        }
        let mut page = vec![0u8; self.page_size];
        match self
            .wal
            .as_ref()
            .and_then(|wal| Some((wal, *wal.pages.get(&page_number)?)))
        {
            Some((wal, offset)) => read_exact_at(&wal.file, &mut page, offset)?,
            None => read_exact_at(
                &self.file,
                &mut page,
                u64::from(page_number - 1) * self.page_size as u64,
            )?,
        }
        Ok(page)
    }
}

fn wal_path(database: &Path) -> std::path::PathBuf {
    let mut wal = OsString::from(database.as_os_str());
    wal.push("-wal");
    wal.into()
}

impl Wal {
    /// Reads the committed frames of `path`. A missing log, or one whose header is not a
    /// valid WAL header for this page size, contributes nothing, as for SQLite itself.
    fn open(path: &Path, page_size: usize) -> Result<Option<Self>> {
        let file = match open_regular(path) {
            Ok(file) => file,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(err.into()),
        };
        let len = file.metadata()?.len();
        if len > MAX_WAL_BYTES {
            return Err(SqliteError::Malformed("write-ahead log too large"));
        }
        if len < WAL_HEADER_LEN as u64 {
            return Ok(None);
        }
        let mut header = [0u8; WAL_HEADER_LEN];
        read_exact_at(&file, &mut header, 0)?;
        let big_endian = match be_u32(&header, 0) {
            WAL_MAGIC_BIG_ENDIAN => true,
            WAL_MAGIC_LITTLE_ENDIAN => false,
            _ => return Ok(None),
        };
        let wal_page_size = be_u32(&header, 8) as usize;
        let checksum = wal_checksum(big_endian, (0, 0), &header[..24]);
        if checksum != (be_u32(&header, 24), be_u32(&header, 28)) {
            return Ok(None);
        }
        if wal_page_size != page_size {
            return Err(SqliteError::Malformed("write-ahead log page size"));
        }
        let salts = (be_u32(&header, 16), be_u32(&header, 20));

        let frame_len = (WAL_FRAME_HEADER_LEN + page_size) as u64;
        let mut running = checksum;
        let mut pending: Vec<(u32, u64)> = Vec::new();
        let mut pages = HashMap::new();
        let mut page_count = None;
        let mut frame = vec![0u8; WAL_FRAME_HEADER_LEN + page_size];
        let mut offset = WAL_HEADER_LEN as u64;
        while offset + frame_len <= len {
            read_exact_at(&file, &mut frame, offset)?;
            if (be_u32(&frame, 8), be_u32(&frame, 12)) != salts {
                break;
            }
            let next = wal_checksum(big_endian, running, &frame[..8]);
            let next = wal_checksum(big_endian, next, &frame[WAL_FRAME_HEADER_LEN..]);
            if next != (be_u32(&frame, 16), be_u32(&frame, 20)) {
                break;
            }
            running = next;
            pending.push((be_u32(&frame, 0), offset + WAL_FRAME_HEADER_LEN as u64));
            let commit_size = be_u32(&frame, 4);
            if commit_size > 0 {
                pages.extend(pending.drain(..));
                page_count = Some(commit_size);
            }
            offset += frame_len;
        }

        Ok(page_count.map(|page_count| Self {
            file,
            pages,
            page_count,
        }))
    }
}

/// SQLite's WAL checksum: two running sums over 32-bit words, read in the byte order the
/// log's magic number names.
fn wal_checksum(big_endian: bool, (mut first, mut second): (u32, u32), bytes: &[u8]) -> (u32, u32) {
    for pair in bytes.as_chunks::<8>().0 {
        let word = |at: usize| {
            let raw = [pair[at], pair[at + 1], pair[at + 2], pair[at + 3]];
            if big_endian {
                u32::from_be_bytes(raw)
            } else {
                u32::from_le_bytes(raw)
            }
        };
        first = first.wrapping_add(word(0)).wrapping_add(second);
        second = second.wrapping_add(word(4)).wrapping_add(first);
    }
    (first, second)
}

fn be_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

#[cfg(unix)]
fn read_exact_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<()> {
    file.read_exact_at(buf, offset)
}

#[cfg(not(unix))]
fn read_exact_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<()> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = file;
    file.seek(SeekFrom::Start(offset))?;
    file.read_exact(buf)
}

fn read_u16(bytes: &[u8], offset: usize) -> Result<u16> {
    bytes
        .get(offset..offset + 2)
        .map(|b| u16::from_be_bytes([b[0], b[1]]))
        .ok_or(SqliteError::Malformed("u16 out of range"))
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32> {
    bytes
        .get(offset..offset + 4)
        .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
        .ok_or(SqliteError::Malformed("u32 out of range"))
}

/// SQLite varint: big-endian, seven bits per byte, the ninth byte contributing all eight.
fn read_varint(bytes: &[u8], offset: usize) -> Result<(u64, usize)> {
    let mut value: u64 = 0;
    for index in 0..9 {
        let byte = *bytes
            .get(offset + index)
            .ok_or(SqliteError::Malformed("varint out of range"))?;
        if index == 8 {
            return Ok(((value << 8) | u64::from(byte), 9));
        }
        value = (value << 7) | u64::from(byte & 0x7f);
        if byte & 0x80 == 0 {
            return Ok((value, index + 1));
        }
    }
    unreachable!("the loop returns by the ninth byte")
}

fn decode_record(payload: &[u8]) -> Result<Vec<Value>> {
    let (header_len, mut cursor) = read_varint(payload, 0)?;
    let header_len =
        usize::try_from(header_len).map_err(|_| SqliteError::Malformed("record header"))?;
    if header_len > payload.len() {
        return Err(SqliteError::Malformed("record header"));
    }
    let mut body = header_len;
    let mut values = Vec::new();
    while cursor < header_len {
        let (serial_type, used) = read_varint(payload, cursor)?;
        cursor += used;
        let (value, len) = decode_value(serial_type, payload, body)?;
        body += len;
        values.push(value);
    }
    Ok(values)
}

fn decode_value(serial_type: u64, payload: &[u8], offset: usize) -> Result<(Value, usize)> {
    let int = |len: usize| -> Result<(Value, usize)> {
        let bytes = payload
            .get(offset..offset + len)
            .ok_or(SqliteError::Malformed("integer column"))?;
        // Sign-extend from the first byte.
        let mut value: i64 = if bytes[0] & 0x80 != 0 { -1 } else { 0 };
        for byte in bytes {
            value = (value << 8) | i64::from(*byte);
        }
        Ok((Value::Integer(value), len))
    };
    match serial_type {
        0 => Ok((Value::Null, 0)),
        1 => int(1),
        2 => int(2),
        3 => int(3),
        4 => int(4),
        5 => int(6),
        6 => int(8),
        7 => {
            payload
                .get(offset..offset + 8)
                .ok_or(SqliteError::Malformed("real column"))?;
            Ok((Value::Real, 8))
        }
        8 => Ok((Value::Integer(0), 0)),
        9 => Ok((Value::Integer(1), 0)),
        10 | 11 => Err(SqliteError::Malformed("reserved serial type")),
        n => {
            let len = usize::try_from((n - 12) / 2)
                .map_err(|_| SqliteError::Malformed("column length"))?;
            let bytes = payload
                .get(offset..offset + len)
                .ok_or(SqliteError::Malformed("column length"))?
                .to_vec();
            if n % 2 == 0 {
                Ok((Value::Blob(bytes), len))
            } else {
                Ok((Value::Text(bytes), len))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varint_decodes_one_two_and_nine_byte_forms() {
        assert_eq!(read_varint(&[0x05], 0).unwrap(), (5, 1));
        assert_eq!(read_varint(&[0x81, 0x00], 0).unwrap(), (128, 2));
        assert_eq!(read_varint(&[0xff; 9], 0).unwrap(), (u64::MAX, 9));
        assert!(read_varint(&[0x81], 0).is_err());
    }

    #[test]
    fn rejects_files_that_are_not_sqlite() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("Packages");
        std::fs::write(&path, vec![0u8; 4096]).unwrap();

        assert!(matches!(
            SqliteDatabase::open(&path),
            Err(SqliteError::NotSqlite)
        ));
    }

    /// A commit frame's database size (bytes 4..8 of its frame header) larger than the
    /// main file's pages plus the pages the log stores must be rejected before it bounds
    /// the b-tree walk, even when the frame's own page number (bytes 0..4) claims that
    /// size. The committed fixture was written by real SQLite; only those two fields are
    /// rewritten, and that frame's checksum is recomputed so the frame is still accepted
    /// as committed.
    #[test]
    fn rejects_a_committed_database_size_beyond_existing_pages() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rpmdb.sqlite");
        std::fs::write(
            &path,
            include_bytes!("../../testdata/executable_ownership/rpmdb_wal.sqlite"),
        )
        .unwrap();
        let mut wal =
            include_bytes!("../../testdata/executable_ownership/rpmdb_wal.sqlite-wal").to_vec();
        std::fs::write(wal_path(&path), &wal).unwrap();
        assert!(SqliteDatabase::open(&path).is_ok());

        let big_endian = be_u32(&wal, 0) == WAL_MAGIC_BIG_ENDIAN;
        let page_size = be_u32(&wal, 8) as usize;
        let frame_len = WAL_FRAME_HEADER_LEN + page_size;
        let frames = (wal.len() - WAL_HEADER_LEN) / frame_len;
        let commit = (0..frames)
            .map(|index| WAL_HEADER_LEN + index * frame_len)
            .rfind(|&at| be_u32(&wal, at + 4) > 0)
            .unwrap();
        let previous = if commit == WAL_HEADER_LEN {
            (be_u32(&wal, 24), be_u32(&wal, 28))
        } else {
            (
                be_u32(&wal, commit - frame_len + 16),
                be_u32(&wal, commit - frame_len + 20),
            )
        };
        let largest_page_number = 0xffff_fffe_u32.to_be_bytes();
        wal[commit..commit + 4].copy_from_slice(&largest_page_number);
        wal[commit + 4..commit + 8].copy_from_slice(&largest_page_number);
        let checksum = wal_checksum(big_endian, previous, &wal[commit..commit + 8]);
        let checksum = wal_checksum(
            big_endian,
            checksum,
            &wal[commit + WAL_FRAME_HEADER_LEN..commit + frame_len],
        );
        wal[commit + 16..commit + 20].copy_from_slice(&checksum.0.to_be_bytes());
        wal[commit + 20..commit + 24].copy_from_slice(&checksum.1.to_be_bytes());
        std::fs::write(wal_path(&path), &wal).unwrap();

        assert!(matches!(
            SqliteDatabase::open(&path),
            Err(SqliteError::Malformed("write-ahead log database size"))
        ));
    }

    /// A b-tree page that names itself as a child (page 1 rewritten as an interior table
    /// page, type 0x05 at offset 100, with no cells and right child 1) is a cycle and
    /// must fail on the first repeat, not after one visit per page in the file.
    #[test]
    fn rejects_a_self_referencing_b_tree_page() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rpmdb.sqlite");
        let mut database =
            include_bytes!("../../testdata/executable_ownership/rpmdb.sqlite").to_vec();
        database[HEADER_LEN] = PAGE_TABLE_INTERIOR;
        database[HEADER_LEN + 3..HEADER_LEN + 5].copy_from_slice(&0u16.to_be_bytes());
        database[HEADER_LEN + 8..HEADER_LEN + 12].copy_from_slice(&1u32.to_be_bytes());
        std::fs::write(&path, &database).unwrap();

        let database = SqliteDatabase::open(&path).unwrap();
        assert!(matches!(
            database.table_root_page("Packages"),
            Err(SqliteError::Malformed("b-tree cycle"))
        ));
    }

    /// In the committed fixture, the third cell of leaf page 6 (a row of the `Packages`
    /// table) spills into overflow page 4, which links to page 5. An overflow page that
    /// links to itself, or a second cell that reuses the same chain, reads a page twice
    /// in one scan and must be rejected instead of being re-read until the payload fills.
    #[test]
    fn rejects_an_overflow_page_read_twice_in_one_scan() {
        const PAGE: usize = 4096;
        const LEAF_CELL_POINTERS: usize = 5 * PAGE + 8;
        fn self_linked(database: &mut [u8]) {
            database[3 * PAGE..3 * PAGE + 4].copy_from_slice(&4u32.to_be_bytes());
        }
        fn shared_chain(database: &mut [u8]) {
            database.copy_within(
                LEAF_CELL_POINTERS + 4..LEAF_CELL_POINTERS + 6,
                LEAF_CELL_POINTERS + 6,
            );
        }
        let fixture = include_bytes!("../../testdata/executable_ownership/rpmdb.sqlite");
        let cases: [fn(&mut [u8]); 2] = [self_linked, shared_chain];
        for corrupt in cases {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("rpmdb.sqlite");
            let mut database = fixture.to_vec();
            corrupt(&mut database);
            std::fs::write(&path, &database).unwrap();

            let database = SqliteDatabase::open(&path).unwrap();
            let root = database.table_root_page("Packages").unwrap().unwrap();
            assert!(matches!(
                database.scan_table(root, |_, _| true),
                Err(SqliteError::Malformed("overflow chain"))
            ));
        }
    }
}
