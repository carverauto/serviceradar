//! Parser for the rpm header blobs stored in the `Packages` table of the rpm sqlite
//! backend. Each blob is a header without its leading magic: a big-endian index count and
//! data length, the index entries, then the data store.
//!
//! Only the tags package ownership needs are read.

const TAG_NAME: u32 = 1000;
const TAG_VERSION: u32 = 1001;
const TAG_RELEASE: u32 = 1002;
const TAG_ARCH: u32 = 1022;
const TAG_OLDFILENAMES: u32 = 1027;
const TAG_FILEMODES: u32 = 1030;
const TAG_DIRINDEXES: u32 = 1116;
const TAG_BASENAMES: u32 = 1117;
const TAG_DIRNAMES: u32 = 1118;

const TYPE_INT16: u32 = 3;
const TYPE_INT32: u32 = 4;
const TYPE_STRING: u32 = 6;
const TYPE_STRING_ARRAY: u32 = 8;
const TYPE_I18NSTRING: u32 = 9;

const INDEX_ENTRY_LEN: usize = 16;
/// Upper bound on index entries, far above any real header.
const MAX_INDEX_ENTRIES: u32 = 65_536;

const S_IFMT: u16 = 0o170_000;
const S_IFREG: u16 = 0o100_000;
const EXECUTE_BITS: u16 = 0o111;

/// The ownership-relevant contents of one installed rpm.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RpmPackage {
    pub name: String,
    /// `version-release`, the form the endpoint inventory records.
    pub version: String,
    pub arch: String,
    /// Absolute paths of regular files with an execute bit. When the header carries no
    /// file modes, every listed path is kept.
    pub executable_paths: Vec<String>,
}

struct IndexEntry {
    tag: u32,
    kind: u32,
    offset: usize,
    count: usize,
}

struct Header<'a> {
    entries: Vec<IndexEntry>,
    data: &'a [u8],
}

pub fn parse(blob: &[u8]) -> Option<RpmPackage> {
    let header = Header::parse(blob)?;
    let name = header.string(TAG_NAME)?;
    let version = header.string(TAG_VERSION).unwrap_or_default();
    let release = header.string(TAG_RELEASE).unwrap_or_default();
    let version = match (version.is_empty(), release.is_empty()) {
        (false, false) => format!("{version}-{release}"),
        (false, true) => version,
        _ => String::new(),
    };
    let arch = header.string(TAG_ARCH).unwrap_or_default();
    let paths = header.file_paths();
    let modes = header.u16_array(TAG_FILEMODES);
    let executable_paths = match modes {
        Some(modes) if modes.len() == paths.len() => paths
            .into_iter()
            .zip(modes)
            .filter(|(_, mode)| mode & S_IFMT == S_IFREG && mode & EXECUTE_BITS != 0)
            .map(|(path, _)| path)
            .collect(),
        _ => paths,
    };

    Some(RpmPackage {
        name,
        version,
        arch,
        executable_paths,
    })
}

impl<'a> Header<'a> {
    fn parse(blob: &'a [u8]) -> Option<Self> {
        let index_count = read_u32(blob, 0)?;
        let data_len = usize::try_from(read_u32(blob, 4)?).ok()?;
        if index_count > MAX_INDEX_ENTRIES {
            return None;
        }
        let index_count = index_count as usize;
        let data_start = 8 + index_count * INDEX_ENTRY_LEN;
        let data = blob.get(data_start..data_start.checked_add(data_len)?)?;
        let mut entries = Vec::with_capacity(index_count);
        for index in 0..index_count {
            let base = 8 + index * INDEX_ENTRY_LEN;
            entries.push(IndexEntry {
                tag: read_u32(blob, base)?,
                kind: read_u32(blob, base + 4)?,
                offset: usize::try_from(read_u32(blob, base + 8)?).ok()?,
                count: usize::try_from(read_u32(blob, base + 12)?).ok()?,
            });
        }
        Some(Self { entries, data })
    }

    fn entry(&self, tag: u32) -> Option<&IndexEntry> {
        self.entries.iter().find(|entry| entry.tag == tag)
    }

    fn string(&self, tag: u32) -> Option<String> {
        let entry = self.entry(tag)?;
        if !matches!(
            entry.kind,
            TYPE_STRING | TYPE_STRING_ARRAY | TYPE_I18NSTRING
        ) {
            return None;
        }
        self.strings_at(entry.offset, 1)?.into_iter().next()
    }

    fn string_array(&self, tag: u32) -> Option<Vec<String>> {
        let entry = self.entry(tag)?;
        if entry.kind != TYPE_STRING_ARRAY {
            return None;
        }
        self.strings_at(entry.offset, entry.count)
    }

    fn strings_at(&self, offset: usize, count: usize) -> Option<Vec<String>> {
        let mut out = Vec::with_capacity(count.min(self.data.len()));
        let mut cursor = offset;
        for _ in 0..count {
            let rest = self.data.get(cursor..)?;
            let end = rest.iter().position(|byte| *byte == 0)?;
            out.push(String::from_utf8_lossy(&rest[..end]).into_owned());
            cursor += end + 1;
        }
        Some(out)
    }

    fn u16_array(&self, tag: u32) -> Option<Vec<u16>> {
        let entry = self.entry(tag)?;
        if entry.kind != TYPE_INT16 {
            return None;
        }
        let bytes = self
            .data
            .get(entry.offset..entry.offset.checked_add(entry.count.checked_mul(2)?)?)?;
        Some(
            bytes
                .chunks_exact(2)
                .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
                .collect(),
        )
    }

    fn u32_array(&self, tag: u32) -> Option<Vec<u32>> {
        let entry = self.entry(tag)?;
        if entry.kind != TYPE_INT32 {
            return None;
        }
        let bytes = self
            .data
            .get(entry.offset..entry.offset.checked_add(entry.count.checked_mul(4)?)?)?;
        Some(
            bytes
                .chunks_exact(4)
                .map(|quad| u32::from_be_bytes([quad[0], quad[1], quad[2], quad[3]]))
                .collect(),
        )
    }

    /// File paths from the compressed (dirnames + basenames + dirindexes) form, falling
    /// back to the legacy flat list.
    fn file_paths(&self) -> Vec<String> {
        if let (Some(basenames), Some(dirnames), Some(dirindexes)) = (
            self.string_array(TAG_BASENAMES),
            self.string_array(TAG_DIRNAMES),
            self.u32_array(TAG_DIRINDEXES),
        ) && basenames.len() == dirindexes.len()
        {
            return basenames
                .iter()
                .zip(dirindexes)
                .filter_map(|(base, dir)| {
                    let dir = dirnames.get(usize::try_from(dir).ok()?)?;
                    Some(format!("{dir}{base}"))
                })
                .collect();
        }
        self.string_array(TAG_OLDFILENAMES).unwrap_or_default()
    }
}

fn read_u32(bytes: &[u8], offset: usize) -> Option<u32> {
    let b = bytes.get(offset..offset + 4)?;
    Some(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}
