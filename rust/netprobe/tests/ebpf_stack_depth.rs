//! Static BPF stack-depth gate over the shipped netprobe eBPF object.
//!
//! Nothing loaded `netprobe_ebpf.o` on any kernel before release, so a program
//! that the verifier rejects builds and ships clean and only fails on the host
//! that runs it. That is how netprobe 0.2.61 shipped for ten releases with an
//! `inet_sock_set_state` program the 6.8 verifier refuses: adding the rhel9
//! layout twin gave the shared emitter a second caller, LLVM stopped inlining
//! it, and a 328-byte callee frame landed under a 168-byte entry --
//! `combined stack size of 2 calls is 544. Too large` (#405).
//!
//! This test reproduces the verifier's `check_max_stack_depth` accounting with
//! no kernel and no privileges, so it runs on RBE in every `make test`:
//!
//! * decode the ELF64 object with std only (no aya-obj dependency to pin),
//! * take every FUNC symbol as a subprogram and scan its instructions for the
//!   deepest r10-relative stack byte, following frame-pointer copies through
//!   `mov` and accumulated `add`/`sub` immediates the way LLVM materialises a
//!   stack slot to hand to a helper,
//! * follow BPF-to-BPF `call` edges through the ELF relocations libbpf uses
//!   (bpf-linker internalises every subprogram, so an entry's call into
//!   `.text` is relocated against the SECTION symbol with the callee index
//!   folded into `imm`: target = st_value + (imm + 1) * 8), falling back to the
//!   pc-relative encoding only when no relocation exists,
//! * charge each frame `round_up(max(depth, 1), 32)` exactly as the kernel
//!   does -- a frame that touches no stack still costs a 32-byte slot -- sum
//!   along every call chain from every program entry, and fail past 512.
//!
//! The scan is a linear pass with no path sensitivity, so it charges every
//! stack byte any instruction in the subprogram can touch; the kernel only
//! charges the paths it explores. That makes this an upper bound in practice,
//! with one known gap: an offset carried through a register-to-register `add`
//! is not tracked, which could under-count a frame LLVM builds that way. The
//! self-checks below exist so the gate cannot silently pass by failing to
//! resolve the very call edges it was written for.
//!
//! Run only through `//rust/netprobe:ebpf_stack_depth_test`, which declares the
//! built object. It is `#[ignore]` so a plain `cargo test` in the crate stays
//! green rather than panicking on the missing input.

use std::collections::{HashMap, HashSet};
use std::fs;

const MAX_BPF_STACK: u32 = 512;
const FRAME_ROUNDING: u32 = 32;

// ELF64 constants.
const SHT_SYMTAB: u32 = 2;
const SHT_STRTAB: u32 = 3;
const SHT_REL: u32 = 9;
const SHF_EXECINSTR: u64 = 0x4;
const STT_FUNC: u8 = 2;

// BPF instruction constants.
const BPF_LD: u8 = 0x00;
const BPF_LDX: u8 = 0x01;
const BPF_ST: u8 = 0x02;
const BPF_STX: u8 = 0x03;
const BPF_ALU: u8 = 0x04;
const BPF_JMP: u8 = 0x05;
const BPF_ALU64: u8 = 0x07;
const BPF_MEM: u8 = 0x60;
const BPF_ATOMIC: u8 = 0xc0;
const BPF_LD_IMM64: u8 = 0x18;
const BPF_MOV64_REG: u8 = 0xbf;
const BPF_ADD64_IMM: u8 = 0x07;
const BPF_SUB64_IMM: u8 = 0x17;
const BPF_CALL: u8 = 0x85;
const BPF_PSEUDO_CALL: usize = 1;
const R10: usize = 10;
const REGISTER_COUNT: usize = 11;

#[derive(Clone, Debug)]
struct Symbol {
    name: String,
    shndx: usize,
    value: u64,
    size: u64,
    kind: u8,
}

#[derive(Clone, Debug)]
struct Function {
    name: String,
    section: usize,
    offset: u64,
    size: u64,
}

#[derive(Debug, Default)]
struct Section {
    name: String,
    kind: u32,
    flags: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    entsize: u64,
}

fn u16_at(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}

fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

fn u64_at(b: &[u8], at: usize) -> u64 {
    let mut raw = [0u8; 8];
    raw.copy_from_slice(&b[at..at + 8]);
    u64::from_le_bytes(raw)
}

fn cstr(strtab: &[u8], at: usize) -> String {
    let end = strtab[at..]
        .iter()
        .position(|&c| c == 0)
        .map(|n| at + n)
        .unwrap_or(strtab.len());
    String::from_utf8_lossy(&strtab[at..end]).into_owned()
}

fn parse_sections(elf: &[u8]) -> Result<Vec<Section>, String> {
    if elf.len() < 64 || &elf[0..4] != b"\x7fELF" {
        return Err("not an ELF file".into());
    }
    if elf[4] != 2 || elf[5] != 1 {
        return Err("expected a little-endian ELF64 object".into());
    }
    let shoff = u64_at(elf, 0x28) as usize;
    let shentsize = u16_at(elf, 0x3a) as usize;
    let shnum = u16_at(elf, 0x3c) as usize;
    let shstrndx = u16_at(elf, 0x3e) as usize;
    if shentsize < 64 || shoff + shnum * shentsize > elf.len() {
        return Err("section header table is out of bounds".into());
    }

    let mut sections = Vec::with_capacity(shnum);
    for index in 0..shnum {
        let at = shoff + index * shentsize;
        sections.push(Section {
            name: String::new(),
            kind: u32_at(elf, at + 4),
            flags: u64_at(elf, at + 8),
            offset: u64_at(elf, at + 24),
            size: u64_at(elf, at + 32),
            link: u32_at(elf, at + 40),
            info: u32_at(elf, at + 44),
            entsize: u64_at(elf, at + 56),
        });
    }

    let names = sections
        .get(shstrndx)
        .ok_or("section name string table index is out of bounds")?;
    let (start, end) = (names.offset as usize, (names.offset + names.size) as usize);
    let strtab = elf
        .get(start..end)
        .ok_or("section name string table is out of bounds")?;
    let name_offsets: Vec<usize> = (0..shnum)
        .map(|index| u32_at(elf, shoff + index * shentsize) as usize)
        .collect();
    for (section, name_at) in sections.iter_mut().zip(name_offsets) {
        section.name = cstr(strtab, name_at);
    }
    Ok(sections)
}

/// Every symbol, in symbol-table order, so relocation symbol indexes resolve
/// directly. Section symbols matter as much as functions here: that is what a
/// call into an internalised `.text` subprogram is relocated against.
fn parse_symbols(elf: &[u8], sections: &[Section]) -> Result<Vec<Symbol>, String> {
    let symtab = sections
        .iter()
        .find(|s| s.kind == SHT_SYMTAB)
        .ok_or("object has no symbol table")?;
    let strtab = sections
        .get(symtab.link as usize)
        .filter(|s| s.kind == SHT_STRTAB)
        .ok_or("symbol table has no string table")?;
    let strings = elf
        .get(strtab.offset as usize..(strtab.offset + strtab.size) as usize)
        .ok_or("symbol string table is out of bounds")?;

    let entsize = if symtab.entsize == 0 {
        24
    } else {
        symtab.entsize as usize
    };
    let count = symtab.size as usize / entsize;
    let mut symbols = Vec::with_capacity(count);
    for index in 0..count {
        let at = symtab.offset as usize + index * entsize;
        if at + entsize > elf.len() {
            return Err("symbol table is out of bounds".into());
        }
        symbols.push(Symbol {
            name: cstr(strings, u32_at(elf, at) as usize),
            shndx: u16_at(elf, at + 6) as usize,
            value: u64_at(elf, at + 8),
            size: u64_at(elf, at + 16),
            kind: elf[at + 4] & 0xf,
        });
    }
    Ok(symbols)
}

fn functions_from(symbols: &[Symbol], sections: &[Section]) -> Result<Vec<Function>, String> {
    let functions: Vec<Function> = symbols
        .iter()
        .filter(|s| s.kind == STT_FUNC && s.size > 0 && s.shndx != 0 && s.shndx < sections.len())
        .map(|s| Function {
            name: s.name.clone(),
            section: s.shndx,
            offset: s.value,
            size: s.size,
        })
        .collect();
    if functions.is_empty() {
        return Err("object has no FUNC symbols".into());
    }
    Ok(functions)
}

/// Relocations applied to a code section, keyed by instruction index and
/// holding the symbol-table index they refer to.
fn parse_call_relocations(
    elf: &[u8],
    sections: &[Section],
    code_section: usize,
) -> HashMap<u64, usize> {
    let mut relocations = HashMap::new();
    for rel in sections
        .iter()
        .filter(|s| s.kind == SHT_REL && s.info as usize == code_section)
    {
        let entsize = if rel.entsize == 0 {
            16
        } else {
            rel.entsize as usize
        };
        let count = rel.size as usize / entsize;
        for index in 0..count {
            let at = rel.offset as usize + index * entsize;
            if at + 16 > elf.len() {
                break;
            }
            let r_offset = u64_at(elf, at);
            let r_info = u64_at(elf, at + 8);
            relocations.insert(r_offset / 8, (r_info >> 32) as usize);
        }
    }
    relocations
}

fn function_at(functions: &[Function], section: usize, byte_offset: u64) -> Option<usize> {
    functions.iter().position(|f| {
        f.section == section && byte_offset >= f.offset && byte_offset < f.offset + f.size
    })
}

#[derive(Debug, Default, Clone)]
struct FrameInfo {
    /// Deepest r10-relative byte touched, as a positive size.
    depth: u32,
    /// Indexes into the function list.
    callees: Vec<usize>,
    /// Pseudo-calls whose target mapped to no FUNC symbol. Each one is a call
    /// edge this analysis cannot follow, so the chain through it is understated.
    unresolved_calls: u32,
}

/// Resolves a relocated pseudo-call the way libbpf and aya-obj do: the target
/// is `st_value + (imm + 1) * 8` inside the symbol's section. For a FUNC symbol
/// imm is -1 and that is st_value; for a SECTION symbol st_value is 0 and imm
/// carries the callee's instruction index.
fn relocated_call_target(
    symbols: &[Symbol],
    functions: &[Function],
    symbol_index: usize,
    imm: i32,
) -> Option<usize> {
    let symbol = symbols.get(symbol_index)?;
    let byte = symbol.value as i64 + (imm as i64 + 1) * 8;
    if byte < 0 {
        return None;
    }
    function_at(functions, symbol.shndx, byte as u64)
}

fn charge(info: &mut FrameInfo, base: Option<i32>, displacement: i32) {
    if let Some(base) = base {
        let effective = base as i64 + displacement as i64;
        if effective < 0 {
            info.depth = info.depth.max((-effective) as u32);
        }
    }
}

fn scan_function(
    elf: &[u8],
    sections: &[Section],
    symbols: &[Symbol],
    functions: &[Function],
    index: usize,
    relocations: &HashMap<u64, usize>,
) -> FrameInfo {
    let function = &functions[index];
    let section = &sections[function.section];
    let start = (section.offset + function.offset) as usize;
    let end = start + function.size as usize;
    let code = &elf[start..end];
    let first_insn = function.offset / 8;

    let mut info = FrameInfo::default();
    // For each register, its known offset from r10 (Some(0) is r10 itself),
    // or None when it holds something that is not a frame pointer.
    let mut fp_offset: [Option<i32>; REGISTER_COUNT] = [None; REGISTER_COUNT];
    fp_offset[R10] = Some(0);

    let mut at = 0usize;
    while at + 8 <= code.len() {
        let opcode = code[at];
        let regs = code[at + 1];
        let dst = (regs & 0x0f) as usize;
        let src = (regs >> 4) as usize;
        let off = i16::from_le_bytes([code[at + 2], code[at + 3]]) as i32;
        let imm = i32::from_le_bytes([code[at + 4], code[at + 5], code[at + 6], code[at + 7]]);
        let insn_index = first_insn + (at / 8) as u64;
        let class = opcode & 0x07;
        let mode = opcode & 0xe0;
        // Register fields are 4 bits; only r0-r10 are real.
        let dst_ok = dst < REGISTER_COUNT;
        let src_ok = src < REGISTER_COUNT;

        match class {
            BPF_LDX if mode == BPF_MEM => {
                // The deepest byte of an access at r10-N is N itself: the access
                // extends upward from there, so its size does not add depth.
                if src_ok {
                    charge(&mut info, fp_offset[src], off);
                }
                if dst_ok && dst != R10 {
                    fp_offset[dst] = None;
                }
            }
            BPF_ST | BPF_STX if (mode == BPF_MEM || mode == BPF_ATOMIC) && dst_ok => {
                charge(&mut info, fp_offset[dst], off);
            }
            BPF_ALU64 => {
                if opcode == BPF_MOV64_REG && dst_ok && dst != R10 {
                    fp_offset[dst] = if src_ok { fp_offset[src] } else { None };
                } else if (opcode == BPF_ADD64_IMM || opcode == BPF_SUB64_IMM)
                    && dst_ok
                    && dst != R10
                    && fp_offset[dst].is_some()
                {
                    // LLVM materialises a stack slot as `rX = r10; rX += -N`
                    // before handing it to a helper. Accumulate, so a second
                    // adjustment is charged as N + M, not M.
                    let delta = if opcode == BPF_ADD64_IMM {
                        imm
                    } else {
                        imm.wrapping_neg()
                    };
                    let next = fp_offset[dst].unwrap_or(0).wrapping_add(delta);
                    fp_offset[dst] = Some(next);
                    charge(&mut info, Some(next), 0);
                } else if dst_ok && dst != R10 {
                    fp_offset[dst] = None;
                }
            }
            BPF_JMP if opcode == BPF_CALL => {
                if src == BPF_PSEUDO_CALL {
                    // Branch on whether a relocation exists, not on whether it
                    // resolved: a relocation that names nothing must not fall
                    // through to the pc-relative reading, which for a SECTION
                    // relocation lands on an unrelated neighbour in the caller's
                    // own section and quietly understates the chain.
                    let target = match relocations.get(&insn_index) {
                        Some(&symbol_index) => {
                            relocated_call_target(symbols, functions, symbol_index, imm)
                        }
                        None => {
                            let target_insn = insn_index as i64 + imm as i64 + 1;
                            if target_insn < 0 {
                                None
                            } else {
                                function_at(functions, function.section, (target_insn as u64) * 8)
                            }
                        }
                    };
                    match target {
                        Some(callee) => {
                            if callee != index && !info.callees.contains(&callee) {
                                info.callees.push(callee);
                            }
                        }
                        None => info.unresolved_calls += 1,
                    }
                }
                // Any call clobbers r0-r5.
                fp_offset[..6].fill(None);
            }
            BPF_LD | BPF_ALU if dst_ok && dst != R10 => {
                fp_offset[dst] = None;
            }
            _ => {}
        }

        at += if opcode == BPF_LD_IMM64 { 16 } else { 8 };
    }
    info
}

/// `round_up(max(depth, 1), 32)`: the kernel charges a frame that touches no
/// stack a full 32-byte slot, and the tracepoint chain has exactly such a leaf
/// (the `+0+` in `168+0+328`).
fn rounded(depth: u32) -> u32 {
    depth.max(1).div_ceil(FRAME_ROUNDING) * FRAME_ROUNDING
}

/// Deepest rounded stack along any call chain from `index`, with the chain.
/// One frame of a call chain: an index into the function list, flagged when
/// the walk hit it a second time.
struct ChainFrame {
    function: usize,
    recursion: bool,
}

fn worst_chain(
    index: usize,
    frames: &[FrameInfo],
    visiting: &mut HashSet<usize>,
) -> (u32, Vec<ChainFrame>) {
    let own = rounded(frames[index].depth);
    if !visiting.insert(index) {
        // A cycle would be rejected by the verifier outright; count it once.
        return (
            own,
            vec![ChainFrame {
                function: index,
                recursion: true,
            }],
        );
    }
    let mut best = (
        own,
        vec![ChainFrame {
            function: index,
            recursion: false,
        }],
    );
    for &callee in &frames[index].callees {
        let (depth, mut chain) = worst_chain(callee, frames, visiting);
        if own + depth > best.0 {
            let mut full = vec![ChainFrame {
                function: index,
                recursion: false,
            }];
            full.append(&mut chain);
            best = (own + depth, full);
        }
    }
    visiting.remove(&index);
    best
}

/// Report rendering only. Checks match on the full symbol name of a frame's
/// function (see `chain_reaches`), never on this display form.
fn render_chain(chain: &[ChainFrame], frames: &[FrameInfo], functions: &[Function]) -> String {
    chain
        .iter()
        .map(|frame| {
            let label = format!(
                "{} [{}]",
                short_name(&functions[frame.function].name),
                rounded(frames[frame.function].depth)
            );
            if frame.recursion {
                format!("{label} (recursion)")
            } else {
                label
            }
        })
        .collect::<Vec<_>>()
        .join(" -> ")
}

fn chain_reaches(chain: &[ChainFrame], functions: &[Function], needle: &str) -> bool {
    chain
        .iter()
        .any(|frame| functions[frame.function].name.contains(needle))
}

/// Display name for reports; a heuristic, not a demangler, so no check may
/// depend on it. Rust v0 mangling keeps identifiers readable as `<len><ident>`
/// runs. A plain path (`_RNv...`) ends with the item name, so its last
/// identifier is right. A generic instantiation (`_RI<path><args>E`) puts the
/// type arguments after the path, so its last identifier is a type -- the
/// shared emitter takes `&impl EbpfContext` and showed up as
/// `TracePointContext` / `ProbeContext`. There the item name is the last
/// identifier of the first identifier run, which ends where the arguments
/// begin. Disambiguators (`s<base62>_`) and backrefs (`B<base62>_`) are skipped
/// so their digits are never read as a length.
fn short_name(mangled: &str) -> String {
    if !mangled.starts_with("_R") {
        return mangled.to_string();
    }
    let generic = mangled.starts_with("_RI");
    let bytes = mangled.as_bytes();
    let mut best = String::new();
    let mut first_run_done = false;
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if (c == b's' || c == b'B')
            && let Some(skip) = base62_suffix_len(&bytes[i + 1..])
        {
            i += 1 + skip;
            continue;
        }
        if !c.is_ascii_digit() {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < bytes.len() && bytes[j].is_ascii_digit() {
            j += 1;
        }
        let Ok(len) = mangled[i..j].parse::<usize>() else {
            i = j;
            continue;
        };
        if len == 0 || j + len > bytes.len() {
            i = j;
            continue;
        }
        let ident = &mangled[j..j + len];
        if !ident.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            i = j;
            continue;
        }
        if !(generic && first_run_done) {
            best = ident.to_string();
        }
        i = j + len;
        if generic && !first_run_done {
            // The run continues through another identifier, optionally behind a
            // disambiguator or a punycode marker; anything else starts the
            // generic arguments.
            let rest = &bytes[i..];
            let continues = match rest.first() {
                Some(b) if b.is_ascii_digit() => true,
                Some(b'u') => rest.get(1).is_some_and(u8::is_ascii_digit),
                Some(b's') => base62_suffix_len(&rest[1..])
                    .is_some_and(|skip| rest.get(1 + skip).is_some_and(u8::is_ascii_digit)),
                _ => false,
            };
            if !continues {
                first_run_done = true;
            }
        }
    }
    if best.is_empty() {
        mangled.to_string()
    } else {
        best
    }
}

/// Length of a `<base62>_` run at the start of `bytes`, if one is there.
fn base62_suffix_len(bytes: &[u8]) -> Option<usize> {
    let digits = bytes
        .iter()
        .take_while(|b| b.is_ascii_alphanumeric())
        .count();
    (bytes.get(digits) == Some(&b'_')).then_some(digits + 1)
}

#[test]
fn short_name_prefers_the_item_over_a_generic_argument() {
    assert_eq!(short_name("memset"), "memset");
    assert_eq!(
        short_name("_RNvCs1a2b3c_13netprobe_ebpf12account_flow"),
        "account_flow"
    );
    assert_eq!(
        short_name(
            "_RINvCs1a2b3c_13netprobe_ebpf28emit_event_with_cached_ownerNtNtNtCs4d5e6f_8aya_ebpf8programs10tracepoint17TracePointContextEC13netprobe_ebpf"
        ),
        "emit_event_with_cached_owner"
    );
    assert_eq!(
        short_name(
            "_RNvXs_NtNtCs4d5e6f_8aya_ebpf8programs10tracepointNtB4_17TracePointContextNtNtB8_7context11EbpfContext6as_ptr"
        ),
        "as_ptr"
    );
}

#[test]
#[ignore = "needs the built netprobe_ebpf.o; run the dedicated Bazel target"]
fn every_program_call_chain_fits_the_bpf_stack() {
    let path = std::env::var("NETPROBE_TEST_EBPF_OBJECT")
        .expect("NETPROBE_TEST_EBPF_OBJECT must name the built netprobe_ebpf.o (declared by the Bazel target)");
    let elf = fs::read(&path).unwrap_or_else(|e| panic!("read {path}: {e}"));

    let sections = parse_sections(&elf).expect("parse ELF sections");
    let symbols = parse_symbols(&elf, &sections).expect("parse symbol table");
    let functions = functions_from(&symbols, &sections).expect("collect FUNC symbols");

    let mut relocations_by_section: HashMap<usize, HashMap<u64, usize>> = HashMap::new();
    let mut frames = Vec::with_capacity(functions.len());
    for (index, function) in functions.iter().enumerate() {
        let relocations = relocations_by_section
            .entry(function.section)
            .or_insert_with(|| parse_call_relocations(&elf, &sections, function.section));
        frames.push(scan_function(
            &elf,
            &sections,
            &symbols,
            &functions,
            index,
            relocations,
        ));
    }

    // Program entries: every function in an executable section other than
    // .text, which holds the shared subprograms. Several programs can share one
    // section (the unnamed #[classifier] ones all live in `classifier`), so
    // this is by symbol, not by section.
    let mut entries: Vec<usize> = functions
        .iter()
        .enumerate()
        .filter(|(_, f)| {
            let section = &sections[f.section];
            section.flags & SHF_EXECINSTR != 0 && section.name != ".text"
        })
        .map(|(index, _)| index)
        .collect();
    entries.sort_by(|&a, &b| functions[a].name.cmp(&functions[b].name));
    assert!(!entries.is_empty(), "object exposes no program entries");

    let mut chains: HashMap<String, (u32, Vec<ChainFrame>)> = HashMap::new();
    let mut report = Vec::new();
    let mut failures = Vec::new();
    for &index in &entries {
        let mut visiting = HashSet::new();
        let (depth, chain) = worst_chain(index, &frames, &mut visiting);
        let name = short_name(&functions[index].name);
        let section = &sections[functions[index].section].name;
        let rendered = render_chain(&chain, &frames, &functions);
        report.push(format!(
            "{name:<32} {section:<44} chain={depth:>3}/{MAX_BPF_STACK}  {rendered}"
        ));
        if depth > MAX_BPF_STACK {
            failures.push(format!("{name}: {depth} > {MAX_BPF_STACK} via {rendered}"));
        }
        chains.insert(name, (depth, chain));
    }

    println!("BPF stack depth per program (frames rounded to {FRAME_ROUNDING} bytes):");
    for line in &report {
        println!("  {line}");
    }

    // --- Self-checks: the gate must be able to fail for the bug it guards. ---

    // Both tracepoint variants must be present; the 6.8 failure was in the one
    // the layout detector selects on that kernel.
    for name in ["inet_sock_set_state", "inet_sock_set_state_rhel9"] {
        assert!(
            chains.contains_key(name),
            "expected tracepoint program {name} in the object"
        );
    }

    // Cross-section call edges must resolve. netprobe_tc_ingress calls helpers
    // that are #[inline(never)] by source, so its chain must be at least two
    // frames deep; a single frame here means relocation resolution is broken and
    // every other chain in this report is understated.
    let (_, tc_chain) = chains
        .get("netprobe_tc_ingress")
        .expect("expected classifier program netprobe_tc_ingress in the object");
    assert!(
        tc_chain.len() >= 2,
        "netprobe_tc_ingress resolved a single frame ({}); its #[inline(never)] helpers live in \
         .text, so BPF-to-BPF call edges are not being resolved",
        render_chain(tc_chain, &frames, &functions)
    );

    // Every BPF-to-BPF call must map to a FUNC symbol. An edge this analysis
    // cannot follow understates the chain silently, which is the one way this
    // gate could pass a broken object.
    let unresolved: Vec<String> = functions
        .iter()
        .zip(&frames)
        .filter(|(_, frame)| frame.unresolved_calls > 0)
        .map(|(function, frame)| {
            format!(
                "{} ({} unresolved)",
                short_name(&function.name),
                frame.unresolved_calls
            )
        })
        .collect();
    assert!(
        unresolved.is_empty(),
        "pseudo-calls with no resolvable target: {}",
        unresolved.join(", ")
    );

    // If the shared emitter is out of line, both tracepoint chains must reach
    // it -- that is the exact 0.2.61 shape. If LLVM inlines it instead there is
    // no such symbol and nothing to assert. Match on the full symbol, not the
    // display name: the emitter is generic over the context type, and v0
    // mangling puts that argument last, so it renders as `TracePointContext`.
    let emitter_out_of_line = functions.iter().any(|f| {
        sections[f.section].name == ".text" && f.name.contains("emit_event_with_cached_owner")
    });
    if emitter_out_of_line {
        for name in ["inet_sock_set_state", "inet_sock_set_state_rhel9"] {
            let (_, chain) = &chains[name];
            assert!(
                chain_reaches(chain, &functions, "emit_event_with_cached_owner"),
                "{name} does not reach the out-of-line emitter: {}",
                render_chain(chain, &frames, &functions)
            );
        }
    }

    assert!(
        failures.is_empty(),
        "programs exceed the {MAX_BPF_STACK}-byte BPF stack (the verifier will reject them):\n  {}",
        failures.join("\n  ")
    );
}
