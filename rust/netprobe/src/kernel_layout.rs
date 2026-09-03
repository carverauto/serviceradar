use std::{collections::HashMap, fs, path::Path};

use anyhow::{Context, Result, bail};

const BTF_MAGIC: u16 = 0xeb9f;
const BTF_KIND_INT: u32 = 1;
const BTF_KIND_ARRAY: u32 = 3;
const BTF_KIND_STRUCT: u32 = 4;
const BTF_KIND_UNION: u32 = 5;
const BTF_KIND_ENUM: u32 = 6;
const BTF_KIND_FUNC_PROTO: u32 = 13;
const BTF_KIND_VAR: u32 = 14;
const BTF_KIND_DATASEC: u32 = 15;
const BTF_KIND_DECL_TAG: u32 = 17;
const BTF_KIND_ENUM64: u32 = 19;

const SOCK_COMMON_FIELDS: [(&str, usize); 7] = [
    ("skc_daddr", 0),
    ("skc_rcv_saddr", 4),
    ("skc_dport", 12),
    ("skc_num", 14),
    ("skc_family", 16),
    ("skc_v6_daddr", 56),
    ("skc_v6_rcv_saddr", 72),
];

#[derive(Clone, Copy)]
enum Endian {
    Little,
    Big,
}

impl Endian {
    fn u16(self, bytes: &[u8]) -> Result<u16> {
        let bytes: [u8; 2] = bytes.try_into().context("BTF: truncated 16-bit integer")?;
        Ok(match self {
            Self::Little => u16::from_le_bytes(bytes),
            Self::Big => u16::from_be_bytes(bytes),
        })
    }

    fn u32(self, bytes: &[u8]) -> Result<u32> {
        let bytes: [u8; 4] = bytes.try_into().context("BTF: truncated 32-bit integer")?;
        Ok(match self {
            Self::Little => u32::from_le_bytes(bytes),
            Self::Big => u32::from_be_bytes(bytes),
        })
    }
}

#[derive(Clone, Copy, Debug)]
struct BtfMember {
    name_offset: u32,
    type_id: u32,
    bit_offset: u32,
}

#[derive(Debug, Default)]
struct BtfType {
    name_offset: u32,
    kind: u32,
    kind_flag: bool,
    size_or_type: u32,
    members: Vec<BtfMember>,
}

struct ParsedBtf<'a> {
    types: Vec<BtfType>,
    strings: &'a [u8],
}

pub(crate) fn ensure_supported_sock_common_layout() -> Result<()> {
    let path = Path::new("/sys/kernel/btf/vmlinux");
    let bytes = fs::read(path).with_context(|| {
        format!(
            "TCP attribution unavailable: cannot read kernel BTF {} to validate struct sock_common",
            path.display()
        )
    })?;
    validate_sock_common_layout(&bytes).context(
        "TCP attribution unavailable: kernel struct sock_common does not match the compiled probe layout",
    )
}

fn validate_sock_common_layout(bytes: &[u8]) -> Result<()> {
    let btf = parse_btf(bytes)?;
    let sock_common_id = btf
        .types
        .iter()
        .enumerate()
        .find_map(|(id, ty)| {
            (ty.kind == BTF_KIND_STRUCT && btf.string(ty.name_offset) == Some("sock_common"))
                .then_some(id as u32)
        })
        .context("BTF: struct sock_common was not found")?;

    let mut observed = HashMap::new();
    for (field, _) in SOCK_COMMON_FIELDS {
        if let Some(bit_offset) = btf.member_bit_offset(sock_common_id, field, 0, 0) {
            if bit_offset % 8 != 0 {
                bail!("BTF: sock_common.{field} is not byte-aligned ({bit_offset} bits)");
            }
            observed.insert(field, bit_offset as usize / 8);
        }
    }
    validate_sock_common_offsets(&observed)
}

fn validate_sock_common_offsets(observed: &HashMap<&str, usize>) -> Result<()> {
    if SOCK_COMMON_FIELDS
        .iter()
        .all(|(field, expected)| observed.get(field) == Some(expected))
    {
        return Ok(());
    }

    let details = SOCK_COMMON_FIELDS
        .iter()
        .map(|(field, expected)| {
            format!(
                "{field}=observed:{:?}/expected:{expected}",
                observed.get(field)
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    bail!("unsupported sock_common field offsets: {details}")
}

fn parse_btf(bytes: &[u8]) -> Result<ParsedBtf<'_>> {
    if bytes.len() < 24 {
        bail!("BTF: header is truncated");
    }
    let endian = match &bytes[..2] {
        [0x9f, 0xeb] => Endian::Little,
        [0xeb, 0x9f] => Endian::Big,
        _ => bail!("BTF: invalid magic"),
    };
    if endian.u16(&bytes[..2])? != BTF_MAGIC {
        bail!("BTF: invalid magic");
    }

    let header_len = endian.u32(&bytes[4..8])? as usize;
    if header_len < 24 || header_len > bytes.len() {
        bail!("BTF: invalid header length {header_len}");
    }
    let type_offset = endian.u32(&bytes[8..12])? as usize;
    let type_len = endian.u32(&bytes[12..16])? as usize;
    let string_offset = endian.u32(&bytes[16..20])? as usize;
    let string_len = endian.u32(&bytes[20..24])? as usize;
    let type_start = header_len
        .checked_add(type_offset)
        .context("BTF: type offset overflow")?;
    let type_end = type_start
        .checked_add(type_len)
        .context("BTF: type length overflow")?;
    let string_start = header_len
        .checked_add(string_offset)
        .context("BTF: string offset overflow")?;
    let string_end = string_start
        .checked_add(string_len)
        .context("BTF: string length overflow")?;
    if type_end > bytes.len() || string_end > bytes.len() {
        bail!("BTF: type or string section exceeds file size");
    }

    // BTF type ids are one-based; preserve index zero as the void/unknown type.
    let mut types = Vec::new();
    types.push(BtfType::default());
    let mut cursor = type_start;
    while cursor < type_end {
        if cursor + 12 > type_end {
            bail!("BTF: truncated type record");
        }
        let name_offset = endian.u32(&bytes[cursor..cursor + 4])?;
        let info = endian.u32(&bytes[cursor + 4..cursor + 8])?;
        let size_or_type = endian.u32(&bytes[cursor + 8..cursor + 12])?;
        cursor += 12;
        let kind = (info >> 24) & 0x1f;
        let kind_flag = info & (1 << 31) != 0;
        let count = (info & 0xffff) as usize;
        let extra_len = match kind {
            BTF_KIND_INT => 4,
            BTF_KIND_ARRAY => 12,
            BTF_KIND_STRUCT | BTF_KIND_UNION => count.saturating_mul(12),
            BTF_KIND_ENUM | BTF_KIND_FUNC_PROTO => count.saturating_mul(8),
            BTF_KIND_VAR | BTF_KIND_DECL_TAG => 4,
            BTF_KIND_DATASEC | BTF_KIND_ENUM64 => count.saturating_mul(12),
            _ => 0,
        };
        if cursor + extra_len > type_end {
            bail!("BTF: truncated kind {kind} payload");
        }

        let mut members = Vec::new();
        if matches!(kind, BTF_KIND_STRUCT | BTF_KIND_UNION) {
            members.reserve(count);
            for index in 0..count {
                let start = cursor + index * 12;
                members.push(BtfMember {
                    name_offset: endian.u32(&bytes[start..start + 4])?,
                    type_id: endian.u32(&bytes[start + 4..start + 8])?,
                    bit_offset: endian.u32(&bytes[start + 8..start + 12])?,
                });
            }
        }
        types.push(BtfType {
            name_offset,
            kind,
            kind_flag,
            size_or_type,
            members,
        });
        cursor += extra_len;
    }

    Ok(ParsedBtf {
        types,
        strings: &bytes[string_start..string_end],
    })
}

impl ParsedBtf<'_> {
    fn string(&self, offset: u32) -> Option<&str> {
        let tail = self.strings.get(offset as usize..)?;
        let end = tail.iter().position(|byte| *byte == 0)?;
        std::str::from_utf8(&tail[..end]).ok()
    }

    fn resolve_type(&self, mut type_id: u32) -> Option<u32> {
        for _ in 0..32 {
            let ty = self.types.get(type_id as usize)?;
            if matches!(ty.kind, BTF_KIND_STRUCT | BTF_KIND_UNION) {
                return Some(type_id);
            }
            if !matches!(ty.kind, 8 | 9 | 10 | 11 | 18) {
                return None;
            }
            type_id = ty.size_or_type;
        }
        None
    }

    fn member_bit_offset(
        &self,
        type_id: u32,
        target: &str,
        base_offset: u32,
        depth: usize,
    ) -> Option<u32> {
        if depth > 16 {
            return None;
        }
        let type_id = self.resolve_type(type_id)?;
        let ty = self.types.get(type_id as usize)?;
        for member in &ty.members {
            let bit_offset = if ty.kind_flag {
                member.bit_offset & 0x00ff_ffff
            } else {
                member.bit_offset
            };
            let name = self.string(member.name_offset).unwrap_or_default();
            if name == target {
                return Some(base_offset.saturating_add(bit_offset));
            }
            if name.is_empty() {
                if let Some(found) = self.member_bit_offset(
                    member.type_id,
                    target,
                    base_offset.saturating_add(bit_offset),
                    depth + 1,
                ) {
                    return Some(found);
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::{SOCK_COMMON_FIELDS, validate_sock_common_offsets};
    use std::collections::HashMap;

    #[test]
    fn accepts_compiled_sock_common_offsets() {
        let observed = SOCK_COMMON_FIELDS.into_iter().collect::<HashMap<_, _>>();
        validate_sock_common_offsets(&observed).unwrap();
    }

    #[test]
    fn rejects_shifted_sock_common_offsets() {
        let observed = SOCK_COMMON_FIELDS
            .into_iter()
            .map(|(field, offset)| (field, offset + 8))
            .collect::<HashMap<_, _>>();
        let error = validate_sock_common_offsets(&observed).unwrap_err();
        assert!(error.to_string().contains("unsupported sock_common"));
    }
}
