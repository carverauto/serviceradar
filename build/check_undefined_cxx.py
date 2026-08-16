"""Fail if a NIF this build compiled left C++ symbols that nothing can resolve.

Sibling of the ELF architecture assertion in //build:mix_app.bzl, for the same
failure -- a shared object that links green and dies at dlopen -- with a different
cause.

`-shared` does not error on undefined symbols. That is deliberate and load-bearing
for a NIF: every one of them references enif_* and expects the BEAM to supply those
at load time. The cost is that a genuinely unresolvable symbol links just as
quietly. ex_libsrt's srt_nif.so shipped with 53 undefined `_ZNSt3__1...` symbols and
no C++ runtime anywhere in the object, built green twice -- once before anyone
looked, and once after a "fix" that linked an empty stub archive -- and would have
failed on the first dlopen. `-z defs` is not the answer here, because it would
reject the enif_* symbols that are supposed to be undefined.

The rule implemented here is narrow on purpose: undefined C++-MANGLED symbols are
acceptable only when the object names a C++ runtime in DT_NEEDED to resolve them
from. That distinction is not defensive padding. vix's priv carries upstream's
libvips-cpp.so, which has 132 undefined `_Z*` symbols and is entirely correct,
because it declares libstdc++.so.6; a check for mangled symbols alone would reject
it on the first run.

Written against the ELF format directly rather than shelling out to llvm-nm, because
the LLVM toolchain's binaries are not in cc_toolchain.all_files and are addressable
only through a repository whose name encodes the host platform. Reading two section
headers is less machinery than plumbing a host-dependent label through the rule.

Usage: check_undefined_cxx.py <directory>
"""

import os
import struct
import sys

# ELF constants: magic, 64-bit class, little-endian. Both architectures this repo
# targets are little-endian, and a big-endian object here would be a much larger
# surprise than this script failing to parse it.
_MAGIC = b"\x7fELF"
_ELFCLASS64 = 2
_ELFDATA2LSB = 1

_DT_NULL = 0
_DT_NEEDED = 1
_SHT_DYNAMIC = 6

# st_info >> 4. A WEAK undefined symbol is not an error: the dynamic linker resolves
# it to 0 rather than failing, which is the whole point of the binding. GCC emits the
# transactional-memory clones of operator new/delete (`_ZGTtnam`, `_ZGTtdlPv`) and TLS
# init functions (`_ZTH...`) exactly this way, so every ffmpeg library Membrane ships
# carries two or three of them and loads perfectly well. Only STRONG undefined symbols
# can fail a dlopen, and those are the only ones worth failing a build over.
_STB_WEAK = 2

_CXX_RUNTIMES = ("libc++", "libstdc++")

# The symbols that actually mean "the C++ standard library was not linked".
#
# `_Z` alone does NOT mean C++. The prefix is shared with manglings that have nothing to
# do with the standard library, and two of them are all over the artefacts Membrane ships:
# glibc's vector-math ABI (`_ZGVdN8vv_powf`, resolved from libmvec.so.1, which every one of
# those objects already names in DT_NEEDED) and GCC's transactional-memory clones
# (`_ZGTtnam`). Matching on `_Z` flagged 36 ffmpeg libraries that load perfectly well.
#
# So match the standard library and the C++ ABI explicitly: std:: entities, __cxxabiv1::
# entities, and the global operator new/delete forms. That is precisely the set that goes
# unresolved when a C++ NIF links no C++ runtime, and it is what srt_nif.so was missing.
_CXX_STDLIB_PREFIXES = (
    "_ZNSt",  # std::  member functions
    "_ZNKSt",  # std::  const member functions
    "_ZSt",  # std::  free functions
    "_ZTISt",  # std::  typeinfo
    "_ZTVSt",  # std::  vtables
    "_ZN10__cxxabiv1",  # __cxxabiv1::
    "_ZNK10__cxxabiv1",
    "_ZTIN10__cxxabiv1",
    "_ZTVN10__cxxabiv1",
    "_Znw",  # operator new
    "_Zna",  # operator new[]
    "_Zdl",  # operator delete
    "_Zda",  # operator delete[]
)

# Bundlex stages each precompiled OS dependency into a directory named after the URL it
# came from, so `.tar.gz/` or `.tar.xz/` in the path means "upstream's binary, not ours".
# Whether ffmpeg links its own C++ runtime correctly is upstream's business; this check is
# about link lines this build produced.
_STAGED_DOWNLOAD_MARKERS = (".tar.gz/", ".tar.xz/", ".tar.bz2/")


def _cstr(data, offset):
    end = data.index(b"\0", offset)
    return data[offset:end].decode("utf-8", "replace")


def _sections(data):
    """Yield (name, type, offset, size, link, entsize) for each section header."""
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    if not e_shoff or not e_shnum:
        return []

    raw = []
    for i in range(e_shnum):
        base = e_shoff + i * e_shentsize
        name, typ = struct.unpack_from("<II", data, base)
        offset, size = struct.unpack_from("<QQ", data, base + 0x18)
        link = struct.unpack_from("<I", data, base + 0x28)[0]
        entsize = struct.unpack_from("<Q", data, base + 0x38)[0]
        raw.append((name, typ, offset, size, link, entsize))

    if e_shstrndx >= len(raw):
        return []
    strtab_off = raw[e_shstrndx][2]

    return [
        (_cstr(data, strtab_off + name), typ, offset, size, link, entsize)
        for (name, typ, offset, size, link, entsize) in raw
    ]


def inspect(path):
    """Return (undefined C++-mangled symbols, DT_NEEDED entries), or None if not ELF64."""
    with open(path, "rb") as handle:
        data = handle.read()

    if len(data) < 0x40 or data[:4] != _MAGIC:
        return None
    if data[4] != _ELFCLASS64 or data[5] != _ELFDATA2LSB:
        return None

    try:
        sections = _sections(data)
    except (struct.error, ValueError):
        return None

    by_name = {name: entry for entry in sections for name in [entry[0]]}

    needed = []
    dynamic = by_name.get(".dynamic")
    dynstr = by_name.get(".dynstr")
    if dynamic and dynstr:
        _, _, dyn_off, dyn_size, _, _ = dynamic
        str_off = dynstr[2]
        for i in range(dyn_size // 16):
            tag, val = struct.unpack_from("<qQ", data, dyn_off + i * 16)
            if tag == _DT_NULL:
                break
            if tag == _DT_NEEDED:
                needed.append(_cstr(data, str_off + val))

    undefined = []
    dynsym = by_name.get(".dynsym")
    if dynsym and dynstr:
        _, _, sym_off, sym_size, _, _ = dynsym
        str_off = dynstr[2]
        for i in range(sym_size // 24):
            name_off, info, _other, shndx = struct.unpack_from(
                "<IBBH", data, sym_off + i * 24
            )
            # st_shndx == SHN_UNDEF means the symbol is referenced, not defined here.
            if shndx != 0 or not name_off:
                continue
            if info >> 4 == _STB_WEAK:
                continue
            symbol = _cstr(data, str_off + name_off)
            if symbol.startswith(_CXX_STDLIB_PREFIXES):
                undefined.append(symbol)

    return undefined, needed


def main(argv):
    if len(argv) != 2:
        print("usage: check_undefined_cxx.py <directory>", file=sys.stderr)
        return 2

    root = argv[1]
    if not os.path.isdir(root):
        return 0

    failures = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for filename in sorted(filenames):
            path = os.path.join(dirpath, filename)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            if any(marker in path for marker in _STAGED_DOWNLOAD_MARKERS):
                continue

            try:
                result = inspect(path)
            except (OSError, struct.error, ValueError):
                continue
            if result is None:
                continue

            undefined, needed = result
            if not undefined:
                continue
            if any(rt in entry for entry in needed for rt in _CXX_RUNTIMES):
                continue

            failures += 1
            rel = os.path.relpath(path, root)
            print(
                "ERROR: %s has %d undefined C++ symbols and links no C++ runtime."
                % (rel, len(undefined)),
                file=sys.stderr,
            )
            print(
                "  It would load nowhere: dlopen fails on the first unresolved symbol.",
                file=sys.stderr,
            )
            print(
                "  Link the static C++ runtime (see _compiles_cxx in //build:mix_app.bzl)",
                file=sys.stderr,
            )
            print("  or declare a shared one. DT_NEEDED is: %s" % (needed or "empty"), file=sys.stderr)
            for symbol in undefined[:5]:
                print("    %s" % symbol, file=sys.stderr)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
